open Core_kernel
open Utils

let find_attr (attrs : (string * string) list) (name_to_find : string) =
  List.find_map attrs ~f:(fun (name, value) ->
    if String.(name = name_to_find) then
      Some value
    else
      None)

let find_attr_exn attrs name_to_find =
  find_attr attrs name_to_find
  |> Option.value_exn ~here:[%here]

let col_of_cell_id id =
  (String.to_list id
   |> List.take_while ~f:Char.is_alpha
   |> List.map ~f:Char.uppercase
   |> List.map ~f:(fun c -> Char.to_int c - Char.to_int 'A' + 1)
   |> List.fold ~init:0 ~f:(fun acc n -> acc * 26 + n))
  - 1

let rec find_elements el ~path =
  match path with
  | [] -> [ el ]
  | search_tag :: tl ->
    match el with
    | Xml.Element (tag, _, children) when String.(tag = search_tag) ->
      List.concat_map children ~f:(find_elements ~path:tl)
    | _ -> []

let elements_to_string els =
  let open Xml in
  List.map els ~f:(function
  | (Element ("r", _, _) as el) ->
    find_elements el ~path:[ "r"; "t" ]
    |> List.filter_map ~f:(function
    | PCData str -> Some str
    | _ -> None)
    |> String.concat ~sep:""
  | Element ("t", _, []) -> ""
  (* Ignore phonetic helpers for now. These are just additional data. *)
  | Element ("rPh", _, _) -> ""
  | Element ("phoneticPr", _, _) -> ""
  | Element ("t", _, [ PCData str] ) -> str
  | el ->
    failwithf "Unexpected shared string element %s"
      (Xml.to_string el) ())
  |> String.concat ~sep:""

module Column = struct
  type t =
    { min : int
    ; max : int }
      [@@deriving compare, fields, sexp]

  let of_xml = function
    | Xml.Element ("col", attrs, _) ->
      let min = find_attr_exn attrs "min" |> Int.of_string in
      let max = find_attr_exn attrs "max" |> Int.of_string in
      Some { min ; max }
    | _ -> None

  let of_worksheet_xml root =
    find_elements root ~path:[ "worksheet" ; "cols" ]
    |> List.filter_map ~f:of_xml
end

module Style = struct
  type t =
    { num_fmt_id : int }
      [@@deriving compare, sexp]

  let of_xml = function
    | Xml.Element ("xf", attrs, _) ->
      let num_fmt_id = find_attr_exn attrs "numFmtId" |> Int.of_string in
      Some { num_fmt_id }
    | _ -> None

  let of_zip zip =
    Zip.find_entry zip "xl/styles.xml"
    |> Zip.read_entry zip
    |> Xml.parse_string
    |> find_elements ~path:[ "styleSheet" ; "cellXfs" ]
    |> List.filter_map ~f:of_xml
end

module Cell = struct
  type value =
    | Boolean of bool
    | Error of string
    (* According to this, Excel seems to store numbers as doubles:
       https://support.office.com/en-us/article/excel-specifications-and-limits-1672b34d-7043-467e-8e27-269d656771c3 *)
    | Number of float
    | String of string
    | Shared_string of int
        [@@deriving compare, sexp]

  type t =
    { column : int
    ; value : value option
    ; style : int }
      [@@deriving compare, sexp]

  let empty column =
    { column ; value = None ; style = 0 }

  let to_string ~styles ~shared_strings { value ; style } =
    Option.map value ~f:(function
    | Boolean true -> "1"
    | Boolean false -> "0"
    | Number n ->
      let add_commas s =
        String.split s ~on:'.'
        |> (function
        | i :: p ->
          (String.to_list_rev i
           |> List.groupi ~break:(fun i _ _ -> i mod 3 = 0)
           |> List.map ~f:List.rev
           |> List.map ~f:String.of_char_list
           |> List.rev
           |> String.concat ~sep:",")
          :: p
        | l -> l)
        |> String.concat ~sep:"."
      in
      (match styles.(style).Style.num_fmt_id with
      | 1 ->
        Float.iround_exn n
        |> Int.to_string
      | 2 ->
        sprintf "%.2f" n
      | 3 ->
        Float.iround_exn n
        |> Int.to_string
        |> add_commas
      | 4 ->
        sprintf "%.2f" n
        |> add_commas
      | 9 ->
        n *. 100.
        |> Float.iround_exn
        |> sprintf "%d%%"
      | 10 ->
        n *. 100.
        |> sprintf "%.2f%%"
      | 11 ->
        sprintf "%.2E" n
      (* TODO: 12 is defined as # ?/?, ex: 1234 4/7 *)
      (* TODO: 13 is defined as # ??/??, ex: 1234 46/81 *)
      | 14 ->
        Date.create_exn ~y:1899 ~m:Month.Dec ~d:30
        |> (fun d -> Date.add_days d (Float.iround_exn ~dir:`Down n))
        |> (fun d ->
          let month = Date.month d |> Month.to_int in
          let day = Date.day d in
          let year = Date.year d in
          sprintf "%d/%d/%d" month day year)
      | 0 | _ ->
        if Float.(round_down n = n) then
          Float.to_int n
          |> sprintf "%d"
        else
          Float.to_string n)
    | Error s
    | String s -> s
    | Shared_string i -> shared_strings.(i))
    |> Option.value ~default:""

  let of_xml xml =
    let open Xml in
    match xml with
    | Element ("c", attrs, _) ->
      let column =
        (* get the column number from the "r" attribute, which looks
           like A1, B1, etc. *)
        find_attr_exn attrs "r"
        |> col_of_cell_id
      in
      let t = List.find_map attrs ~f:(function
        | "t", value -> Some value
        | _ -> None)
      in
      let style =
        List.find_map attrs ~f:(function
        | "s", value -> Some (Int.of_string value)
        | _ -> None)
        |> Option.value ~default:0
      in
      let value =
        match t with
        | Some "inlineStr" ->
          let s =
            find_elements xml ~path:[ "c" ; "is" ]
            |> elements_to_string
          in
          Some (String s)
        | _ ->
          find_elements xml ~path:[ "c" ; "v" ]
          |> List.find_map ~f:(function
          | PCData v ->
            Some (match t with
              | Some "s" ->
                let i = Int.of_string v in
                Shared_string i
              | Some "str" ->
                String v
              | Some "b" ->
                Boolean (match v with
                  | "1" -> true
                  | "0" -> false
                  | _ -> failwithf "Invalid boolean cell value %s" v ())
              | Some "e" ->
                Error v
              | Some "n"
              | None ->
                Number (Float.of_string v)
              | Some t -> failwithf "Invalid cell type %s" t ())
          | _ -> None)
      in
      Some { column ; value ; style }
    | _ -> None
end

module Row = struct
  type t =
    { index : int
    ; cells : Cell.t list }
      [@@deriving compare, fields, sexp]

  let of_xml ~shared_strings =
    let open Xml in
    function
    | Element ("row", attrs, cells) ->
      let index = find_attr_exn attrs "r" |> Int.of_string in
      let row =
        let cell_map =
          List.filter_map cells ~f:Cell.of_xml
          |> List.map ~f:(fun cell ->
            cell.Cell.column, cell)
          |> Int.Map.of_alist_exn
        in
        let n =
          Map.keys cell_map
          |> List.max_elt ~cmp:Int.compare
          |> Option.map ~f:((+) 1)
          |> Option.value ~default:0
        in
        List.init n ~f:Fn.id
        |> List.map ~f:(fun column ->
          Map.find cell_map column
          |> Option.value ~default:(Cell.empty column))
      in
      (* Rows at 1-indexed, convert to 0-indexed *)
      Some { index = index - 1 ; cells = row }
    | _ -> None

  let of_worksheet_xml ~shared_strings root =
    find_elements root ~path:[ "worksheet" ; "sheetData" ]
    |> List.filter_map ~f:(of_xml ~shared_strings)
end

module Worksheet = struct
  type t =
    { columns : Column.t list
    ; rows : Row.t list }
      [@@deriving compare, fields, sexp]

  let of_xml ~shared_strings root =
    let columns = Column.of_worksheet_xml root in
    let rows = Row.of_worksheet_xml ~shared_strings root in
    { columns ; rows }
end

type sheet =
  { name : string
  ; rows : string list list }
    [@@deriving compare, sexp]

type t = sheet list [@@deriving compare, sexp]

let read_file filename =
  let zip = Zip.open_in filename in
  Exn.protect ~f:(fun () ->
    let shared_strings =
      zip_entry_to_xml zip "xl/sharedStrings.xml"
      |> Spreadsheetml.Shared_string_table.of_xml
      |> Spreadsheetml.Shared_string_table.to_string_array
    in
    let sheets =
      zip_entry_to_xml zip "xl/workbook.xml"
      |> Spreadsheetml.Workbook.of_xml
      |> Spreadsheetml.Workbook.sheets
    in
    let styles =
      Style.of_zip zip
      |> Array.of_list
    in
    let rel_map =
      zip_entry_to_xml zip "xl/_rels/workbook.xml.rels"
      |> Open_packaging.Relationships.of_xml
      |> List.map ~f:(fun { Open_packaging.Relationship.id ; target } ->
        id, target)
      |> String.Map.of_alist_exn
    in
    List.map sheets ~f:(fun { Spreadsheetml.Workbook.Sheet.name ; id } ->
      let rows =
        let target = Map.find_exn rel_map id in
        let path = sprintf "xl/%s" target in
        let worksheet =
          Zip.find_entry zip path
          |> Zip.read_entry zip
          |> Xml.parse_string
          |> Worksheet.of_xml ~shared_strings
        in
        let num_cols =
          worksheet.Worksheet.columns
          |> List.map ~f:Column.max
          |> List.max_elt ~cmp:Int.compare
          |> Option.value ~default:0
        in
        let row_map =
          worksheet.Worksheet.rows
          |> List.map ~f:(fun { Row.index ; cells } ->
            index, cells)
          |> Int.Map.of_alist_exn
        in
        let n =
          Map.keys row_map
          |> List.max_elt ~cmp:Int.compare
          |> Option.map ~f:((+) 1)
          |> Option.value ~default:0
        in
        List.init n ~f:Fn.id
        |> List.map ~f:(fun i ->
          let row =
            Map.find row_map i
            |> Option.value ~default:[]
          in
          let missing_cols = num_cols - List.length row in
          if missing_cols > 0 then
            row @ List.init ~f:Cell.empty missing_cols
          else
            row)
        |> List.map ~f:(List.map ~f:(Cell.to_string ~styles ~shared_strings))
      in
      { name ; rows }))
    ~finally:(fun () -> Zip.close_in zip)
