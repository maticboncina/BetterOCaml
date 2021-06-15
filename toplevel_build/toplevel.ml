open Js_of_ocaml
open Js_of_ocaml_lwt
open Js_of_ocaml_tyxml
open Js_of_ocaml_toplevel
open Lwt

let compiler_name = "OCaml"

let by_id s = Dom_html.getElementById s

let by_id_coerce s f =
  Js.Opt.get (f (Dom_html.getElementById s)) (fun () -> raise Not_found)

let do_by_id s f = try f (Dom_html.getElementById s) with Not_found -> ()

(* load file using a synchronous XMLHttpRequest *)
let load_resource_aux filename url =
  Js_of_ocaml_lwt.XmlHttpRequest.perform_raw ~response_type:XmlHttpRequest.ArrayBuffer url
  >|= fun frame ->
  if frame.Js_of_ocaml_lwt.XmlHttpRequest.code = 200
  then
    Js.Opt.case
      frame.Js_of_ocaml_lwt.XmlHttpRequest.content
      (fun () -> Printf.eprintf "Could not load %s\n" filename)
      (fun b ->
        Sys_js.update_file ~name:filename ~content:(Typed_array.String.of_arrayBuffer b))
  else ()

let load_resource scheme ~prefix ~path:suffix =
  let url = scheme ^ suffix in
  let filename = Filename.concat prefix suffix in
  Lwt.async (fun () -> load_resource_aux filename url);
  Some ""

let setup_pseudo_fs () =
  Sys_js.mount ~path:"/dev/" (fun ~prefix:_ ~path:_ -> None);
  Sys_js.mount ~path:"/http/" (load_resource "http://");
  Sys_js.mount ~path:"/https/" (load_resource "https://");
  Sys_js.mount ~path:"/ftp/" (load_resource "ftp://");
  Sys_js.mount ~path:"/home/" (load_resource "filesys/")

let exec' s =
  let res : bool = JsooTop.use Format.std_formatter s in
  if not res then Format.eprintf "error while evaluating %s@." s

module Version = struct
  type t = int list

  let split_char ~sep p =
    let len = String.length p in
    let rec split beg cur =
      if cur >= len
      then if cur - beg > 0 then [ String.sub p beg (cur - beg) ] else []
      else if sep p.[cur]
      then String.sub p beg (cur - beg) :: split (cur + 1) (cur + 1)
      else split beg (cur + 1)
    in
    split 0 0

  let split v =
    match
      split_char
        ~sep:(function
          | '+' | '-' | '~' -> true
          | _ -> false)
        v
    with
    | [] -> assert false
    | x :: _ ->
        List.map
          int_of_string
          (split_char
             ~sep:(function
               | '.' -> true
               | _ -> false)
             x)

  let current = split Sys.ocaml_version

  let compint (a : int) b = compare a b

  let rec compare v v' =
    match v, v' with
    | [ x ], [ y ] -> compint x y
    | [], [] -> 0
    | [], y :: _ -> compint 0 y
    | x :: _, [] -> compint x 0
    | x :: xs, y :: ys -> (
        match compint x y with
        | 0 -> compare xs ys
        | n -> n)
end

let setup_toplevel () =
  JsooTop.initialize ();
  Sys.interactive := false;
  if Version.compare Version.current [ 4; 07 ] >= 0 then exec' "open Stdlib";
  exec'
    "module Lwt_main = struct\n\
    \             let run t = match Lwt.state t with\n\
    \               | Lwt.Return x -> x\n\
    \               | Lwt.Fail e -> raise e\n\
    \               | Lwt.Sleep -> failwith \"Lwt_main.run: thread didn't return\"\n\
    \            end";
  let header = Printf.sprintf "        %s version %%s" compiler_name in
  exec' (Printf.sprintf "Format.printf \"%s@.\" Sys.ocaml_version;;" header);
  exec' "#enable \"pretty\";;";
  exec' "#disable \"shortvar\";;";
  Ppx_support.init ();
  Hashtbl.add
    Toploop.directive_table
    "load_js"
    (Toploop.Directive_string (fun name -> Js.Unsafe.global##load_script_ name));
  Sys.interactive := true;
  ()

let resize ~container ~textbox () =
  Lwt.pause ()
  >>= fun () ->
  textbox##.style##.height := Js.string "auto";
  textbox##.style##.height
  := Js.string (Printf.sprintf "%dpx" (max 18 textbox##.scrollHeight));
  container##.scrollTop := container##.scrollHeight;
  Lwt.return ()

let setup_printers () =
  exec'
    "let _print_error fmt e = Format.pp_print_string fmt (Js_of_ocaml.Js.string_of_error \
     e)";
  Topdirs.dir_install_printer Format.std_formatter Longident.(Lident "_print_error");
  exec' "let _print_unit fmt (_ : 'a) : 'a = Format.pp_print_string fmt \"()\"";
  Topdirs.dir_install_printer Format.std_formatter Longident.(Lident "_print_unit")

let parse_hash () =
  let frag = Url.Current.get_fragment () in
  Url.decode_arguments frag

let rec iter_on_sharp ~f x =
  Js.Opt.iter (Dom_html.CoerceTo.element x) (fun e ->
      if Js.to_bool (e##.classList##contains (Js.string "sharp")) then f e);
  match Js.Opt.to_option x##.nextSibling with
  | None -> ()
  | Some n -> iter_on_sharp ~f n

let current_position = ref 0

let highlight_location loc =
  let x = ref 0 in
  let output = by_id "output" in
  let first =
    Js.Opt.get (output##.childNodes##item !current_position) (fun _ -> assert false)
  in
  iter_on_sharp first ~f:(fun e ->
      incr x;
      let _file1, line1, col1 = Location.get_pos_info loc.Location.loc_start in
      let _file2, line2, col2 = Location.get_pos_info loc.Location.loc_end in
      if !x >= line1 && !x <= line2
      then
        let from_ = if !x = line1 then `Pos col1 else `Pos 0 in
        let to_ = if !x = line2 then `Pos col2 else `Last in
        Colorize.highlight from_ to_ e)

let append colorize output cl s =
  Dom.appendChild output (Tyxml_js.To_dom.of_element (colorize ~a_class:cl s))

let append_to_console s =
  Firebug.console##log (Js.string s)

module History = struct
  let data = ref [| "" |]

  let idx = ref 0

  let get_storage () =
    match Js.Optdef.to_option Dom_html.window##.localStorage with
    | exception _ -> raise Not_found
    | None -> raise Not_found
    | Some t -> t

  let setup () =
    try
      let s = get_storage () in
      match Js.Opt.to_option (s##getItem (Js.string "history")) with
      | None -> raise Not_found
      | Some s ->
          let a = Json.unsafe_input s in
          data := a;
          idx := Array.length a - 1
    with _ -> ()

  let push text =
    let l = Array.length !data in
    let n = Array.make (l + 1) "" in
    !data.(l - 1) <- text;
    Array.blit !data 0 n 0 l;
    data := n;
    idx := l;
    try
      let s = get_storage () in
      let str = Json.output !data in
      s##setItem (Js.string "history") str
    with Not_found -> ()

  let current text = !data.(!idx) <- text

  let previous textbox =
    if !idx > 0
    then (
      decr idx;
      textbox##.value := Js.string !data.(!idx))

  let next textbox =
    if !idx < Array.length !data - 1
    then (
      incr idx;
      textbox##.value := Js.string !data.(!idx))
end

let run _ =
  let container = by_id "toplevel-container" in
  let output = by_id "output" in
  let textbox : 'a Js.t = by_id_coerce "userinput" Dom_html.CoerceTo.textarea in
  let sharp_chan = open_out "/dev/null0" in
  let sharp_ppf = Format.formatter_of_out_channel sharp_chan in
  let caml_chan = open_out "/dev/null1" in
  let caml_ppf = Format.formatter_of_out_channel caml_chan in
  let binsharp_chan = open_out "/dev/null2" in
  let binsharp_ppf = Format.formatter_of_out_channel binsharp_chan in
  let bincaml_chan = open_out "/dev/null3" in
  let bincaml_ppf = Format.formatter_of_out_channel bincaml_chan in
  let consolecaml_chan = open_out "/dev/null3" in
  let consolecaml_ppf = Format.formatter_of_out_channel consolecaml_chan in
  let execute () =
    let content = Js.to_string textbox##.value##trim in
    let content' =
      let len = String.length content in
      if try content <> "" && content.[len - 1] <> ';' && content.[len - 2] <> ';'
         with _ -> true
      then content ^ ";;"
      else if try content <> "" && content.[len - 1] = ';' && content.[len - 2] <> ';'
         with _ -> true
      then content ^ ";"
      else content
    in
    current_position := output##.childNodes##.length;
    textbox##.value := Js.string "";
    History.push content;
    JsooTop.execute true ~pp_code:sharp_ppf ~highlight_location caml_ppf content';
    resize ~container ~textbox ()
    >>= fun () ->
    container##.scrollTop := container##.scrollHeight;
    Lwt.return_unit
  in
  let execute_callback mode content =
      let content' =
        let len = String.length content in
        if try content <> "" && content.[len - 1] <> ';' && content.[len - 2] <> ';'
           with _ -> true
        then content ^ ";;"
        else if try content <> "" && content.[len - 1] = ';' && content.[len - 2] <> ';'
           with _ -> true
        then content ^ ";"
        else content
      in match mode with
      |"internal" -> JsooTop.execute true ~pp_code:binsharp_ppf ~highlight_location bincaml_ppf content'
      |"console" -> JsooTop.execute true ~pp_code:binsharp_ppf ~highlight_location consolecaml_ppf content'
      |"toplevel" -> (
          current_position := output##.childNodes##.length;
          History.push content;
          JsooTop.execute true ~pp_code:sharp_ppf ~highlight_location caml_ppf content';
          resize ~container ~textbox ()
          >>= fun () ->
          container##.scrollTop := container##.scrollHeight;
      )
      |"" -> ();
      Lwt.return_unit
  in

  let history_down _e =
    let txt = Js.to_string textbox##.value in
    let pos = textbox##.selectionStart in
    try
      if String.length txt = pos then raise Not_found;
      let _ = String.index_from txt pos '\n' in
      Js._true
    with Not_found ->
      History.current txt;
      History.next textbox;
      Js._false
  in
  let history_up _e =
    let txt = Js.to_string textbox##.value in
    let pos = textbox##.selectionStart - 1 in
    try
      if pos < 0 then raise Not_found;
      let _ = String.rindex_from txt pos '\n' in
      Js._true
    with Not_found ->
      History.current txt;
      History.previous textbox;
      Js._false
  in
  let meta e =
    let b = Js.to_bool in
    b e##.ctrlKey || b e##.altKey || b e##.metaKey
  in
  let shift e = Js.to_bool e##.shiftKey in
  (* setup handlers *)
  textbox##.onkeyup :=
    Dom_html.handler (fun _ ->
        Lwt.async (resize ~container ~textbox);
        Js._true);
  textbox##.onchange :=
    Dom_html.handler (fun _ ->
        Lwt.async (resize ~container ~textbox);
        Js._true);
  textbox##.onkeydown :=
    Dom_html.handler (fun e ->
        match e##.keyCode with
        | 13 when not (meta e || shift e) ->
            Lwt.async execute;
            Js._false
        | 13 ->
            Lwt.async (resize ~container ~textbox);
            Js._true
        | 09 ->
            Indent.textarea textbox;
            Js._false
        | 76 when meta e ->
            output##.innerHTML := Js.string "";
            Js._true
        | 75 when meta e ->
            setup_toplevel ();
            Js._false
        | 38 -> history_up e
        | 40 -> history_down e
        | _ -> Js._true);
  (Lwt.async_exception_hook :=
     fun exc ->
       Format.eprintf "exc during Lwt.async: %s@." (Printexc.to_string exc);
       match exc with
       | Js.Error e -> Firebug.console##log e##.stack
       | _ -> ());
  Lwt.async (fun () ->
      resize ~container ~textbox ()
      >>= fun () ->
      textbox##focus;
      Lwt.return_unit);
  Sys_js.set_channel_flusher caml_chan (append Colorize.ocaml output "caml");
  Sys_js.set_channel_flusher sharp_chan (append Colorize.ocaml output "sharp");
  Sys_js.set_channel_flusher stdout (append Colorize.text output "stdout");
  Sys_js.set_channel_flusher stderr (append Colorize.text output "stderr");
  Sys_js.set_channel_flusher consolecaml_chan append_to_console;
  let readline () =
    Js.Opt.case
      (Dom_html.window##prompt (Js.string "The toplevel expects inputs:") (Js.string ""))
      (fun () -> "")
      (fun s -> Js.to_string s ^ "\n")
  in
  Sys_js.set_channel_filler stdin readline;
  setup_pseudo_fs ();
  setup_toplevel ();
  setup_printers ();
  History.setup ();
  textbox##.value := Js.string "";
  (* Add callback*)
  Js.Unsafe.global##.executecallback := (object%js
        val execute = Js.wrap_meth_callback
            (fun _ mode content -> execute_callback (Js.to_string mode) (Js.to_string content))
      end);
  (* Run initial code if any *)
  try
    let code = List.assoc "code" (parse_hash ()) in
    textbox##.value := Js.string (B64.decode code);
    Lwt.async execute
  with
  | Not_found -> ()
  | exc ->
      Firebug.console##log_3
        (Js.string "exception")
        (Js.string (Printexc.to_string exc))
        exc



let _ =
  Dom_html.window##.onload :=
    Dom_html.handler (fun _ ->
        run ();
        Js._false);
  Js.Unsafe.global##.toplevelcallback := (object%js
      val setup_toplevel = Js.wrap_meth_callback
          (fun () -> setup_toplevel ())
    end)
