(* LVM compatible bits and pieces *)

open Cmdliner
open Lwt


(* lvcreate -n <name> vgname -l <size_in_percent> -L <size_in_mb> --addtag tag *)
let lvcreate copts lv_name real_size percent_size tags vg_name action =
  let open Xenvm_common in
  let info = Lwt_main.run (
    get_vg_info_t copts vg_name >>= fun info ->
    set_uri copts info;
    Client.get () >>= fun vg ->

    let extent_size_bytes = Int64.(mul 512L vg.Lvm.Vg.extent_size) in

    (* XXX: Need to guard against integer overflow here *)
    let size = match parse_size real_size percent_size with
    | `Absolute size -> size
    | `Extents extents -> Int64.mul extent_size_bytes extents
    | `Free percent ->
      let extents = Int64.(div (mul (Lvm.Pv.Allocator.size vg.Lvm.Vg.free_space) percent) 100L) in
      let bytes = Int64.mul extent_size_bytes extents in
      bytes
    | _ -> failwith "Initial size must be absolute" in
    if vg.Lvm.Vg.name <> vg_name then failwith "Invalid VG name";
    let creation_host = Unix.gethostname () in
    let creation_time = Unix.gettimeofday () |> Int64.of_float in
    Lwt.catch
      (fun () ->
        Client.create lv_name size creation_host creation_time tags
      ) (function
        | Xenvm_interface.Insufficient_free_space(needed, available) ->
          Printf.fprintf Pervasives.stderr "Volume group \"%s\" has insufficient free space (%Ld extents): %Ld required.\n%!" vg.Lvm.Vg.name available needed;
          exit 5
        | e -> fail e
    ) >>= fun () ->
    return info) in
  (* Activate the volume by default unless requested otherwise *)
  match action with
  | Some Xenvm_common.Deactivate -> ()
  | _ ->
    (match info with Some i -> Lvchange.lvchange_activate copts vg_name lv_name (Some i.local_device) false | None -> ())

let lv_name_arg =
  let doc = "Gives the name of the LV to be created. This must be unique within the volume group. " in
  Arg.(value & opt string "lv" & info ["n"; "name"] ~docv:"LVNAME" ~doc)

let vg_name_arg =
  let doc = "Specify the volume group in which to create the logical volume." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"VOLUMEGROUP" ~doc)

let tags_arg =
  let doc = "Specify that a tag should be added to the LV when it is created. This may be specified more than once to add multiple tags." in
  Arg.(value & opt_all string [] & info ["addtag"] ~docv:"TAG" ~doc)

let lvcreate_cmd =
  let doc = "Create a logical volume" in    
  let man = [
    `S "DESCRIPTION";
    `P "lvcreate creates a new logical volume in a volume group by allocating logical extents from the free physical extent pool of that volume group.  If there are not enough free physical extents then the volume group can be extended with other physical volumes or by reducing existing logical volumes of this volume group in size."
  ] in
  Term.(pure lvcreate $ Xenvm_common.copts_t $ lv_name_arg $ Xenvm_common.real_size_arg $ Xenvm_common.percent_size_arg $ tags_arg $ vg_name_arg $ Xenvm_common.action_arg),
  Term.info "lvcreate" ~sdocs:"COMMON OPTIONS" ~doc ~man

  
