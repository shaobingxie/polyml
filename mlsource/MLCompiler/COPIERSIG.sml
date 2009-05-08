(*
	Copyright (c) 2009 David C.J. Matthews

	This library is free software; you can redistribute it and/or
	modify it under the terms of the GNU Lesser General Public
	License as published by the Free Software Foundation; either
	version 2.1 of the License, or (at your option) any later version.
	
	This library is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	Lesser General Public License for more details.
	
	You should have received a copy of the GNU Lesser General Public
	License along with this library; if not, write to the Free Software
	Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

signature COPIERSIG =
sig
    type signatures
    type typeConstrs
    type structVals
    type values
    type typeId

    type tsvEnv = { enterType:   string * typeConstrs -> unit,
                  enterStruct: string * structVals  -> unit,
                  enterVal   : string * values      -> unit };
    val copySig: signatures * (int -> bool) * (int -> typeId) * string -> signatures
    val copySigAndRenumber: signatures * (int -> bool) * (int -> typeId) * int * string -> signatures

    val fullCopySig: signatures * tsvEnv * (typeId -> typeId) * string -> unit
    val copyTypeConstructors: signatures * (typeId -> typeId) * string -> unit
    
    val fullCopyDatatype: typeConstrs * (typeId -> typeId) * string -> typeConstrs
    
    structure Sharing:
    sig
        type signatures     = signatures
        type typeConstrs    = typeConstrs
        type structVals     = structVals
        type values         = values
        type typeId         = typeId
    end
end;