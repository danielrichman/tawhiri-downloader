open Core
open Common
module Log = Async.Log

module F : sig
  type grib_handle_and_data

  val grib_handle_new_from_message : Bigstring.t -> grib_handle_and_data Or_error.t
  val grib_get_int : grib_handle_and_data -> string -> int Or_error.t
  val grib_get_double : grib_handle_and_data -> string -> float Or_error.t

  val grib_get_double_array_into
    :  grib_handle_and_data
    -> string
    -> (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
    -> unit Or_error.t
end = struct
  open Ctypes
  open Foreign
  module Gc = Core.Gc

  type grib_handle_struct

  let grib_handle_struct : grib_handle_struct structure typ = structure "grib_handle"

  type grib_handle = grib_handle_struct structure ptr

  let grib_handle = ptr grib_handle_struct
  let grib_handle_or_null = ptr_opt grib_handle_struct

  type grib_handle_and_data = grib_handle * Bigstring.t

  let grib_get_error_message =
    let f = foreign "grib_get_error_message" (int @-> returning string_opt) in
    fun c ->
      match f c with
      | None -> sprintf "unknown grib error %i" c
      | Some s -> s
  ;;

  let grib_check = function
    | 0 -> Ok ()
    | error_code -> Or_error.error_string (grib_get_error_message error_code)
  ;;

  let grib_handle_delete = foreign "grib_handle_delete" (grib_handle @-> returning int)

  let grib_handle_new_from_message =
    let f =
      foreign
        "grib_handle_new_from_message"
        (ptr_opt void @-> ptr char @-> size_t @-> returning grib_handle_or_null)
    in
    let finaliser (handle, _bs) =
      match grib_handle_delete handle with
      | 0 -> ()
      | e ->
        Log.Global.error
          "grib_handle_new_from_message error finalising %s"
          (grib_get_error_message e)
    in
    fun bigstr ->
      let data = array_of_bigarray array1 bigstr in
      match f None (CArray.start data) (Unsigned.Size_t.of_int (CArray.length data)) with
      | None -> Or_error.error_string "grib_handle_new_from_message"
      | Some handle ->
        let t = handle, bigstr in
        Gc.minor ();
        Gc.Expert.add_finalizer_exn t finaliser;
        Ok t
  ;;

  let grib_get_long =
    let f =
      foreign "grib_get_long" (grib_handle @-> string @-> ptr long @-> returning int)
    in
    fun (handle, _) key ->
      let temp = allocate long (Signed.Long.of_int 0) in
      match grib_check (f handle key temp) with
      | Error _ as error -> error
      | Ok () -> Ok (Signed.Long.to_int64 !@temp)
  ;;

  let grib_get_int t key =
    match grib_get_long t key with
    | Error _ as error -> error
    | Ok res ->
      (match Int64.to_int res with
      | Some x -> Ok x
      | None -> error_s [%sexp "variable Int64.to_int", (key : string), (res : Int64.t)])
  ;;

  let grib_get_double =
    let f =
      foreign "grib_get_double" (grib_handle @-> string @-> ptr double @-> returning int)
    in
    fun (handle, _) key ->
      let temp = allocate double 0. in
      match grib_check (f handle key temp) with
      | Error _ as error -> error
      | Ok () -> Ok !@temp
  ;;

  let grib_get_double_array_into =
    let f1 =
      foreign "grib_get_size" (grib_handle @-> string @-> ptr size_t @-> returning int)
    in
    let f2 =
      foreign
        ~release_runtime_lock:true
        "grib_get_double_array"
        (grib_handle @-> string @-> ptr double @-> ptr size_t @-> returning int)
    in
    let check_size_match got ~expect =
      if [%compare.equal: Unsigned.Size_t.t] got (Unsigned.Size_t.of_int expect)
      then Ok ()
      else Or_error.errorf !"Size mismatch: got %{Unsigned.Size_t} expected %i" got expect
    in
    fun (handle, _) key target ->
      let len_temp = allocate size_t Unsigned.Size_t.zero in
      let%bind.Result () = grib_check (f1 handle key len_temp) in
      let len_expect = Bigarray.Array1.dim target in
      let%bind.Result () = check_size_match !@len_temp ~expect:len_expect in
      let vals = array_of_bigarray array1 target in
      assert (CArray.length vals = len_expect);
      let len_temp = allocate size_t (Unsigned.Size_t.of_int len_expect) in
      let%bind.Result () = grib_check (f2 handle key (CArray.start vals) len_temp) in
      let%bind.Result () = check_size_match !@len_temp ~expect:len_expect in
      Ok ()
  ;;
end

type t = F.grib_handle_and_data

let of_bigstring = F.grib_handle_new_from_message

let variable t =
  let g = F.grib_get_int t in
  let%bind.Result a = g "discipline" in
  let%bind.Result b = g "parameterCategory" in
  let%bind.Result c = g "parameterNumber" in
  match a, b, c with
  | 0, 3, 5 -> Ok Variable.Height
  | 0, 2, 2 -> Ok Variable.U_wind
  | 0, 2, 3 -> Ok Variable.V_wind
  | a, b, c -> Or_error.errorf "couldn't identify variable %i %i %i" a b c
;;

let layout t =
  let gi = F.grib_get_int t in
  let gd = F.grib_get_double t in
  let%bind.Result a = gi "iScansNegatively" in
  let%bind.Result b = gi "jScansPositively" in
  let%bind.Result c = gi "Ni" in
  let%bind.Result d = gi "Nj" in
  let%bind.Result e = gd "latitudeOfFirstGridPointInDegrees" in
  let%bind.Result f = gd "longitudeOfFirstGridPointInDegrees" in
  let%bind.Result g = gd "latitudeOfLastGridPointInDegrees" in
  let%bind.Result h = gd "longitudeOfLastGridPointInDegrees" in
  let%bind.Result i = gd "iDirectionIncrementInDegrees" in
  let%bind.Result j = gd "jDirectionIncrementInDegrees" in
  let%bind.Result k = gi "numberOfValues" in
  match a, b, c, d, e, f, g, h, i, j, k with
  | 0, 0, 720, 361, 90., 0., -90., 359.5, 0.5, 0.5, 259920 -> Ok Layout.Half_deg
  | a, b, c, d, e, f, g, h, i, j, k ->
    Or_error.errorf
      "couldn't identify layout %i %i %i %i %f %f %f %f %f %f %i"
      a
      b
      c
      d
      e
      f
      g
      h
      i
      j
      k
;;

let hour t =
  let gi = F.grib_get_int t in
  let%bind.Result a = gi "stepUnits" in
  let%bind.Result b = gi "forecastTime" in
  match a, b with
  | 1, n -> Hour.of_int n
  | a, b -> Or_error.errorf "couldn't identify hour %i %i" a b
;;

let level t =
  let gi = F.grib_get_int t in
  let%bind.Result a = gi "typeOfFirstFixedSurface" in
  let%bind.Result b = gi "scaleFactorOfFirstFixedSurface" in
  let%bind.Result c = gi "scaledValueOfFirstFixedSurface" in
  let%bind.Result d = gi "level" in
  match a, b, c, d with
  | 100, 0, n, m when n = m * 100 -> Level.of_mb m
  | a, b, c, d -> Or_error.errorf "couldn't identify level %i %i %i %i" a b c d
;;

(* Take care around threads. *)
let with_temp_array =
  let mutex = Error_checking_mutex.create () in
  let arr = Bigarray.(Array1.create Float64 C_layout (720 * 361)) in
  fun f ->
    Error_checking_mutex.lock mutex;
    protectx ~f arr ~finally:(fun _ -> Error_checking_mutex.unlock mutex)
;;

let blit =
  let module B = Bigarray in
  let module B2 = Bigarray.Array2 in
  let check_dims dst =
    if B2.dim1 dst = 361 && B2.dim2 dst = 720
    then Ok ()
    else Or_error.error_string "Output array has bad dims"
  in
  fun t (dst : (float, B.float32_elt, B.c_layout) B2.t) ->
    let%bind.Result () = check_dims dst in
    let%bind.Result Half_deg = layout t in
    with_temp_array (fun temp ->
        match F.grib_get_double_array_into t "values" temp with
        | Error _ as error -> error
        | Ok () ->
          for lat = 0 to 361 - 1 do
            for lon = 0 to 720 - 1 do
              let v = Bigarray.Array1.get temp (((360 - lat) * 720) + lon) in
              B2.set dst lat lon v
            done
          done;
          Ok ())
;;
