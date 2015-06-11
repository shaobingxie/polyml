(*
    Title:      Source level debugger for Poly/ML
    Author:     David Matthews
    Copyright  (c)   David Matthews 2000, 2014, 2015

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License version 2.1 as published by the Free Software Foundation.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

functor DEBUGGER_ (

    structure STRUCTVALS : STRUCTVALSIG
    structure VALUEOPS : VALUEOPSSIG
    structure CODETREE : CODETREESIG
    structure TYPETREE: TYPETREESIG
    structure ADDRESS : AddressSig
    structure COPIER: COPIERSIG
    structure TYPEIDCODE: TYPEIDCODESIG
    structure LEX : LEXSIG

    structure DEBUG :
    sig
        val debugTag: bool Universal.tag
        val getParameter :
           'a Universal.tag -> Universal.universal list -> 'a
    end

    structure UTILITIES :
    sig
        val splitString: string -> { first:string,second:string }
    end

sharing STRUCTVALS.Sharing = VALUEOPS.Sharing = TYPETREE.Sharing = COPIER.Sharing =
        TYPEIDCODE.Sharing = CODETREE.Sharing = ADDRESS = LEX.Sharing
)
: DEBUGGERSIG
=
struct
    open STRUCTVALS VALUEOPS CODETREE COPIER TYPETREE DEBUG

    (* The static environment contains these kinds of entries. *)
    datatype environEntry =
        EnvValue of string * types * locationProp list
    |   EnvException of string * types * locationProp list
    |   EnvVConstr of string * types * bool * int * locationProp list
    |   EnvTypeid of { original: typeId, freeId: typeId }
    |   EnvStructure of string * signatures * locationProp list
    |   EnvTConstr of string * typeConstrSet
    |   EnvStartFunction of string * location * types
    |   EnvEndFunction of string * location * types

    (* Entries in the thread data.  The RTS allocates enough space for this.
       The first entry is 5 because earlier entries are used by Thread.Thread. *)
    (* "Data" entries. *)
    local
        open ADDRESS
    in
        val threadIdStack           = mkConst(toMachineWord 0w5) (* The static/dynamic/location entries for calling fns *)
        and threadIdCurrentStatic   = mkConst(toMachineWord 0w6) (* The static info for bindings i.e. name/type. *)
        and threadIdCurrentDynamic  = mkConst(toMachineWord 0w7) (* Dynamic infor for bindings i.e. actual run-time value. *)
        and threadIdCurrentLocation = mkConst(toMachineWord 0w8) (* Location in code: line number/offset etc. *)
        (* "Function" entries.  Initially zero. *)
        and threadIdOnEntry         = mkConst(toMachineWord 0w9)
        and threadIdOnExit          = mkConst(toMachineWord 0w10)
        and threadIdOnExitExc       = mkConst(toMachineWord 0w11)
        and threadIdBreakPoint      = mkConst(toMachineWord 0w12)
    end

    (* When stopped at a break-point any Bound ids must be replaced by Free ids.
       We make new Free ids at this point.  *)
    fun envTypeId (id as TypeId{ description, idKind = Bound _, ...}) =
            EnvTypeid { original = id, freeId = makeFreeId(Global CodeZero, isEquality id, description) }
    |   envTypeId id = EnvTypeid { original = id, freeId = id }

    fun searchEnvs match (staticEntry :: statics, dlist as dynamicEntry :: dynamics) =
    (
        case (match (staticEntry, dynamicEntry), staticEntry) of
            (SOME result, _) => SOME result
        |   (NONE, EnvTypeid _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvVConstr _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvValue _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvException _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvStructure _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvStartFunction _) => searchEnvs match (statics, dynamics)
        |   (NONE, EnvEndFunction _) => searchEnvs match (statics, dynamics)
                (* EnvTConstr doesn't have an entry in the dynamic list *)
        |   (NONE, EnvTConstr _) => searchEnvs match (statics, dlist)
            
    )
    |   searchEnvs _ ([], []) = NONE
    
    |   searchEnvs _ _ = raise Misc.InternalError "searchEnvs: Static and dynamic lists have different lengths"

    fun searchType envs typeid =
    let
        fun match (EnvTypeid{original, freeId }, valu) =
            if sameTypeId(original, typeid)
            then 
                case freeId of
                    TypeId{description, idKind as Free _, typeFn, ...} =>
                        (* This can occur for datatypes inside functions. *)
                        SOME(TypeId { access= Global(mkConst valu), idKind=idKind, description=description, typeFn = typeFn })
                |   _ => raise Misc.InternalError "searchType: TypeFunction"
            else NONE
        |   match _ = NONE
    in
        case (searchEnvs match envs, typeid) of
            (SOME t, _) => t
        |   (NONE, typeid as TypeId{description, typeFn=(_, EmptyType), ...}) =>
                (* The type ID is missing.  Make a new temporary ID. *)
                makeFreeId(Global(TYPEIDCODE.codeForUniqueId()), isEquality typeid, description)

        |   (NONE, TypeId{description, typeFn, ...}) => makeTypeFunction(description, typeFn)
    end

    fun runTimeType debugEnviron ty =
    let
        fun copyId(TypeId{idKind=Free _, access=Global _ , ...}) = NONE (* Use original *)
        |   copyId id = SOME(searchType debugEnviron id)
    in
            copyType (ty, fn x => x,
                fn tcon => copyTypeConstr (tcon, copyId, fn x => x, fn s => s))
    end

    (* Exported functions that appear in PolyML.DebuggerInterface. *)
    type debugState = environEntry list * machineWord list * location

    fun debugNameSpace ((clist, rlist, _): debugState) : nameSpace =
    let
        val debugEnviron = (clist, rlist)
        (* Values must be copied so that compile-time type IDs are replaced by their run-time values. *)
        fun copyTheTypeConstructor (TypeConstrSet(tcons, (*tcConstructors*) _)) =
        let
            val typeID = searchType debugEnviron (tcIdentifier tcons)
            val newTypeCons =
                makeTypeConstructor(tcName tcons, tcTypeVars tcons, typeID, tcLocations tcons)

            val newValConstrs = (*map copyAConstructor tcConstructors*) []
        in
            TypeConstrSet(newTypeCons, newValConstrs)
        end

        (* When creating a structure we have to add a type map that will look up the bound Ids. *)
        fun replaceSignature (Signatures{ name, tab, typeIdMap, firstBoundIndex, declaredAt, ... }) =
        let
            fun getFreeId n = searchType debugEnviron (makeBoundId(Global CodeZero, n, false, false, basisDescription ""))
        in
            makeSignature(name, tab, firstBoundIndex, declaredAt, composeMaps(typeIdMap, getFreeId), [])
        end

        val runTimeType = runTimeType debugEnviron

        (* Lookup and "all" functions for the environment.  We can't easily use a general
           function for the lookup because we have dynamic entries for values and structures
           but not for type constructors. *)
        fun lookupValues (EnvValue(name, ty, location) :: ntl, valu :: vl) s =
                if name = s
                then SOME(mkGvar(name, runTimeType ty, mkConst valu, location))
                else lookupValues(ntl, vl) s

        |  lookupValues (EnvException(name, ty, location) :: ntl, valu :: vl) s =
                if name = s
                then SOME(mkGex(name, runTimeType ty, mkConst valu, location))
                else lookupValues(ntl, vl) s

        |  lookupValues (EnvVConstr(name, ty, nullary, count, location) :: ntl, valu :: vl) s =
                if name = s
                then SOME(makeValueConstr(name, runTimeType ty, nullary, count, Global(mkConst valu), location))
                else lookupValues(ntl, vl) s

        |  lookupValues (EnvTConstr _ :: ntl, vl) s = lookupValues(ntl, vl) s
        
        |  lookupValues (_ :: ntl, _ :: vl) s = lookupValues(ntl, vl) s

        |  lookupValues _ _ =
             (* The name we are looking for isn't in
                the environment.
                The lists should be the same length. *)
             NONE

        fun allValues (EnvValue(name, ty, location) :: ntl, valu :: vl) =
                (name, mkGvar(name, runTimeType ty, mkConst valu, location)) :: allValues(ntl, vl)

         |  allValues (EnvException(name, ty, location) :: ntl, valu :: vl) =
                (name, mkGex(name, runTimeType ty, mkConst valu, location)) :: allValues(ntl, vl)

         |  allValues (EnvVConstr(name, ty, nullary, count, location) :: ntl, valu :: vl) =
                (name, makeValueConstr(name, runTimeType ty, nullary, count, Global(mkConst valu), location)) ::
                    allValues(ntl, vl)

         |  allValues (EnvTConstr _ :: ntl, vl) = allValues(ntl, vl)
         |  allValues (_ :: ntl, _ :: vl) = allValues(ntl, vl)
         |  allValues _ = []

        fun lookupTypes (EnvTConstr (name, tcSet) :: ntl, vl) s =
                if name = s
                then SOME (copyTheTypeConstructor tcSet)
                else lookupTypes(ntl, vl) s

        |   lookupTypes (_ :: ntl, _ :: vl) s = lookupTypes(ntl, vl) s
        |   lookupTypes _ _ = NONE

        fun allTypes (EnvTConstr(name, tcSet) :: ntl, vl) =
                (name, copyTheTypeConstructor tcSet) :: allTypes(ntl, vl)
         |  allTypes (_ :: ntl, _ :: vl) = allTypes(ntl, vl)
         |  allTypes _ = []

        fun lookupStructs (EnvStructure (name, rSig, locations) :: ntl, valu :: vl) s =
                if name = s
                then SOME(makeGlobalStruct (name, replaceSignature rSig, mkConst valu, locations))
                else lookupStructs(ntl, vl) s

        |   lookupStructs (EnvTConstr _ :: ntl, vl) s = lookupStructs(ntl, vl) s
        |   lookupStructs (_ :: ntl, _ :: vl) s = lookupStructs(ntl, vl) s
        |   lookupStructs _ _ = NONE

        fun allStructs (EnvStructure (name, rSig, locations) :: ntl, valu :: vl) =
                (name, makeGlobalStruct(name, replaceSignature rSig, mkConst valu, locations)) :: allStructs(ntl, vl)

         |  allStructs (EnvTypeid _ :: ntl, _ :: vl) = allStructs(ntl, vl)
         |  allStructs (_ :: ntl, vl) = allStructs(ntl, vl)
         |  allStructs _ = []

        (* We have a full environment here for future expansion but at
           the moment only some of the entries are used. *)
        fun noLook _ = NONE
        and noEnter _ = raise Fail "Cannot update this name space"
        and allEmpty _ = []
   in
       {
            lookupVal = lookupValues debugEnviron,
            lookupType = lookupTypes debugEnviron,
            lookupFix = noLook,
            lookupStruct = lookupStructs debugEnviron,
            lookupSig = noLook, lookupFunct = noLook, enterVal = noEnter,
            enterType = noEnter, enterFix = noEnter, enterStruct = noEnter,
            enterSig = noEnter, enterFunct = noEnter,
            allVal = fn () => allValues debugEnviron,
            allType = fn () => allTypes debugEnviron,
            allFix = allEmpty,
            allStruct = fn () => allStructs debugEnviron,
            allSig = allEmpty,
            allFunct = allEmpty }
    end

    (* debugFunction just looks at the static data. *)
    fun debugFunction (cList, _, _) =
    (
        case List.find(fn (EnvStartFunction _) => true | _ => false) cList of
            SOME(EnvStartFunction(s, _, _)) => SOME s
        |   _ => NONE
    )

    and debugFunctionArg (cList, rList, _) =
    let
        val d = (cList, rList)
        fun match (EnvStartFunction(_, _, ty), valu) =
            SOME(mkGvar("", runTimeType d ty, mkConst valu, []))
        |   match _ = NONE
    in
        searchEnvs match d
    end

    and debugFunctionResult (cList, rList, _) =
    let
        val d = (cList, rList)
        fun match (EnvEndFunction(_, _, ty), valu) =
            SOME(mkGvar("", runTimeType d ty, mkConst valu, []))
        |   match _ = NONE
    in
        searchEnvs match d
    end

    fun debugLocation (_, _, locn) = locn

    (* Functions to make the debug entries.   These are needed both in CODEGEN_PARSETREE for
       the core language and STRUCTURES for the module language. *)
    (* Debugger status within the compiler.
       During compilation the environment is built up as a pair
       consisting of the static data and code to compute the run-time data.
       The static data, a constant at run-time, holds the
       variable names and types.  The run-time code, when executed at
       run-time, returns the address of a list holding the actual values
       of the variables. "dynEnv" is always a "load" from a (codetree)
       variable.  It has type level->codetree rather than codetree
       because the next reference could be inside an inner function.
       "lastLoc" is the last location that was *)
    type debuggerStatus =
        {staticEnv: environEntry list, dynEnv: level->codetree, lastLoc: location}
    
    val initialDebuggerStatus: debuggerStatus =
        {staticEnv = [], dynEnv = fn _ => CodeZero, lastLoc = LEX.nullLocation }

    (* Set the current state in the thread data. *)
    fun updateState (level, mkAddr) (decs, debugEnv: debuggerStatus as {staticEnv, dynEnv, ...}) =
    let
        open ADDRESS RuntimeCalls
        val threadId = multipleUses(mkEval(rtsFunction POLY_SYS_thread_self, []), fn () => mkAddr 1, level)
        fun assignItem(offset, value) =
            mkNullDec(mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, offset, value]))
        val newDecs =
            decs @ #dec threadId @
                [assignItem(threadIdCurrentStatic, mkConst(toMachineWord staticEnv)),
                 assignItem(threadIdCurrentDynamic, dynEnv level)]
    in
        (newDecs, debugEnv)
    end

    fun makeValDebugEntries (vars: values list, debugEnv: debuggerStatus, level, lex, mkAddr, typeVarMap) =
    if getParameter debugTag (LEX.debugParams lex)
    then
        let
            fun loadVar (var, (decs, {staticEnv, dynEnv, lastLoc, ...})) =
                let
                    val loadVal =
                        codeVal (var, level, typeVarMap, [], lex, LEX.nullLocation)
                    val newEnv =
                    (* Create a new entry in the environment. *)
                          mkTuple [ loadVal (* Value. *), dynEnv level ]
                    val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
                    val ctEntry =
                        case var of
                            Value{class=Exception, name, typeOf, locations, ...} =>
                                EnvException(name, typeOf, locations)
                        |   Value{class=Constructor{nullary, ofConstrs, ...}, name, typeOf, locations, ...} =>
                                EnvVConstr(name, typeOf, nullary, ofConstrs, locations)
                        |   Value{name, typeOf, locations, ...} =>
                                EnvValue(name, typeOf, locations)
                in
                    (decs @ dec, {staticEnv = ctEntry :: staticEnv, dynEnv = load, lastLoc = lastLoc})
                end
        in
            updateState (level, mkAddr) (List.foldl loadVar ([], debugEnv) vars)
        end
    else ([], debugEnv)

    fun makeTypeConstrDebugEntries(typeCons, debugEnv, level, lex, mkAddr) =
    if not (getParameter debugTag (LEX.debugParams lex))
    then ([], debugEnv)
    else
    let
        fun foldIds(tc :: tcs, {staticEnv, dynEnv, lastLoc, ...}) =
            let
                val cons = tsConstr tc
                val id = tcIdentifier cons
                val {second = typeName, ...} = UTILITIES.splitString(tcName cons)
            in
                if isTypeFunction (tcIdentifier(tsConstr tc))
                then foldIds(tcs, {staticEnv=EnvTConstr(typeName, tc) :: staticEnv, dynEnv=dynEnv, lastLoc = lastLoc})
                else
                let
                    (* This code will build a cons cell containing the run-time value
                       associated with the type Id as the hd and the rest of the run-time
                       environment as the tl. *)                
                    val loadTypeId = TYPEIDCODE.codeId(id, level)
                    val newEnv = mkTuple [ loadTypeId, dynEnv level ]
                    val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
                    (* Make an entry for the type constructor itself as well as the new type id.
                       The type Id is used both for the type constructor and also for any values
                       of the type. *)
                    val (decs, newEnv) =
                        foldIds(tcs, {staticEnv=EnvTConstr(typeName, tc) :: envTypeId id :: staticEnv, dynEnv=load, lastLoc = lastLoc})
                in
                    (dec @ decs, newEnv)
                end
            end
        |   foldIds([], debugEnv) = ([], debugEnv)
    in
        updateState (level, mkAddr) (foldIds(typeCons, debugEnv))
    end

    fun makeStructDebugEntries (strs: structVals list, debugEnv, level, lex, mkAddr) =
    if getParameter debugTag (LEX.debugParams lex)
    then
        let
            fun loadStruct (str as Struct { name, signat, locations, ...}, (decs, {staticEnv, dynEnv, lastLoc, ...})) =
                let
                    val loadStruct = codeStruct (str, level)
                    val newEnv = mkTuple [ loadStruct (* Structure. *), dynEnv level ]
                    val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
                    val ctEntry = EnvStructure(name, signat, locations)
                in
                    (decs @ dec, {staticEnv=ctEntry :: staticEnv, dynEnv=load, lastLoc = lastLoc})
                end
        in
            updateState (level, mkAddr) (List.foldl loadStruct ([], debugEnv) strs)
        end
    else ([], debugEnv)

    (* Create debug entries for typeIDs.  The idea is that if we stop in the debugger we
       can access the type ID, particularly for printing values of the type.
       "envTypeId" creates a free id for each bound id but the print and equality
       functions are extracted when we are stopped in the debugger. *)
    fun makeTypeIdDebugEntries(typeIds, debugEnv, level, lex, mkAddr) =
    if not (getParameter debugTag (LEX.debugParams lex))
    then ([], debugEnv)
    else
    let
        fun foldIds(id :: ids, {staticEnv, dynEnv, lastLoc, ...}) =
            let
                (* This code will build a cons cell containing the run-time value
                   associated with the type Id as the hd and the rest of the run-time
                   environment as the tl. *)                
                val loadTypeId =
                    case id of TypeId { access = Formal addr, ... } =>
                        (* If we are processing functor arguments we will have a Formal here. *)
                        mkInd(addr, mkLoadArgument 0)
                    |   _ => TYPEIDCODE.codeId(id, level)
                val newEnv = mkTuple [ loadTypeId, dynEnv level ]
                val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
                val (decs, newEnv) =
                    foldIds(ids, {staticEnv=envTypeId id :: staticEnv, dynEnv=load, lastLoc = lastLoc})
            in
                (dec @ decs, newEnv)
            end
        |   foldIds([], debugEnv) = ([], debugEnv)
    in
        updateState (level, mkAddr) (foldIds(typeIds, debugEnv))
    end

    (* Update the location info in the thread data if we want debugging info.
       If the location has not changed don't do anything.  Whether it has changed
       could depend on whether we're only counting line numbers or whether we
       have more precise location info with the IDE. *)
    fun updateDebugLocation(debuggerStatus as {staticEnv, dynEnv, lastLoc, ...}, location, lex) =
    if not (getParameter debugTag (LEX.debugParams lex)) orelse lastLoc = location
    then ([], debuggerStatus)
    else
    let
        open ADDRESS RuntimeCalls
        val setLocation =
            mkEval(rtsFunction POLY_SYS_assign_word,
                [mkEval(rtsFunction POLY_SYS_thread_self, []), threadIdCurrentLocation, mkConst(toMachineWord location)])
    in
        ([mkNullDec setLocation], {staticEnv=staticEnv, dynEnv=dynEnv, lastLoc=location})
    end

    (* Function entry code.  This needs to precede any values in the body. *)
    fun debugFunctionEntryCode(name: string, argCode, argType, location, debugEnv as {staticEnv, dynEnv, lastLoc, ...}, level, lex, mkAddr) =
    if not (getParameter debugTag (LEX.debugParams lex)) then ([], debugEnv)
    else
    let
        val functionName = name (* TODO: munge this to get the root. *)
        val newEnv = mkTuple [ argCode, dynEnv level ]
        val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
        val ctEntry = EnvStartFunction(functionName, location, argType)
    in
        (dec, {staticEnv = ctEntry :: staticEnv, dynEnv = load, lastLoc = lastLoc})
    end

    (* Add debugging calls on entry and exit to a function. *)
    fun wrapFunctionInDebug(body: codetree, name: string, resType: types, location,
                            entryEnv: debuggerStatus as {staticEnv, dynEnv, ...}, level, lex, mkAddr) =
        if not (getParameter debugTag (LEX.debugParams lex)) then body (* Return it unchanged. *)
        else
        let
            open ADDRESS RuntimeCalls
            
            val functionName = name (* TODO: munge this to get the root. *)
            
            fun addStartExitEntry({staticEnv, dynEnv, lastLoc, ...}, code, ty, startExit) =
            let
                val newEnv = mkTuple [ code, dynEnv level ]
                val { dec, load } = multipleUses (newEnv, fn () => mkAddr 1, level)
                val ctEntry = startExit(functionName, location, ty)
            in
                (dec, {staticEnv=ctEntry :: staticEnv, dynEnv=load, lastLoc = lastLoc})
            end

            (* All the "on" functions take this as an argument. *)
            val onArgs = [mkConst(toMachineWord(functionName, location))]

            val threadId = multipleUses(mkEval(rtsFunction POLY_SYS_thread_self, []), fn () => mkAddr 1, level)
            fun loadIdEntry offset =
                multipleUses(mkEval(rtsFunction POLY_SYS_load_word, [#load threadId level, offset]), fn () => mkAddr 1, level)
            val currStatic = loadIdEntry threadIdCurrentStatic
            and currDynamic = loadIdEntry threadIdCurrentDynamic
            and currLocation = loadIdEntry threadIdCurrentLocation
            and currStack = loadIdEntry threadIdStack
            
            val prefixCode =
                #dec threadId @ #dec currStatic @ #dec currDynamic @ #dec currLocation @ #dec currStack
            
            local
                (* At the start of the function:
                   1.  Push the previous state to the stack.
                   2.  Update the state to the state on entry, including the args
                   3.  Call the global onEntry function if it's set
                   4.  Call the local onEntry function if it's set *)
                val assignStack =
                    mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, threadIdStack,
                        mkDatatype[
                            #load currStatic level, #load currDynamic level,
                            #load currLocation level, #load currStack level]])
                val assignStatic =
                    mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, threadIdCurrentStatic,
                        mkConst(toMachineWord staticEnv)])
                val assignDynamic =
                    mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, threadIdCurrentDynamic,
                        dynEnv level])
                val assignLocation =
                    mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, threadIdCurrentLocation,
                        mkConst(toMachineWord location)])
                val onEntryFn = loadIdEntry threadIdOnEntry
                val optCallOnEntry =
                    mkIf(mkTagTest(#load onEntryFn level, 0w0, 0w0), CodeZero, mkEval(#load onEntryFn level, onArgs))
            in
                val entryCode =
                    [mkNullDec assignStack, mkNullDec assignStatic, mkNullDec assignDynamic, mkNullDec assignLocation] @
                    #dec onEntryFn @ [mkNullDec optCallOnEntry]
            end
            
            (* Restore the state.  Used both if the function returns normally or if
               it raises an exception.  We use the old state rather than popping the stack
               because that is more reliable if we have an asynchronous exception. *)
            local
                (* Set the entry in the thread vector to an entry from the top-of-stack. *)
                fun restoreEntry(offset, value) =
                    mkNullDec(
                        mkEval(rtsFunction POLY_SYS_assign_word, [#load threadId level, offset, value]))
            in
                val restoreState =
                    [restoreEntry(threadIdCurrentStatic, #load currStatic level),
                     restoreEntry(threadIdCurrentDynamic, #load currDynamic level),
                     restoreEntry(threadIdCurrentLocation, #load currLocation level),
                     restoreEntry(threadIdStack, #load currStack level)]
            end

            local
                (* If an exception is raised we need to call the onExitException entry, restore the state
                   and reraise the exception. *)
                (* There are potential race conditions here if we have asynchronous exceptions. *)
                val savedExn = multipleUses(Ldexc, fn () => mkAddr 1, level)
                val onExitExcFn = loadIdEntry threadIdOnExitExc
                (* OnExitException has an extra curried argument - the exception packet. *)
                val optCallOnExitExc =
                    mkIf(mkTagTest(#load onExitExcFn level, 0w0, 0w0), CodeZero,
                        mkEval(mkEval(#load onExitExcFn level, onArgs), [#load savedExn level]))
            in
                val exceptionCase =
                    mkEnv(#dec savedExn @ #dec onExitExcFn @  [mkNullDec optCallOnExitExc]  @ restoreState,
                        mkRaise(#load savedExn level))
            end
            
            (* Code for the body and the exception. *)
            val bodyCode =
                multipleUses(mkHandle(body, exceptionCase), fn () => mkAddr 1, level)

            (* Code for normal exit. *)
            local
                val endFn = addStartExitEntry(entryEnv, #load bodyCode level, resType, EnvEndFunction)
                val (rtEnvDec, _) = updateState (level, mkAddr) endFn

                val onExitFn = loadIdEntry threadIdOnExit
                val optCallOnExit =
                    mkIf(mkTagTest(#load onExitFn level, 0w0, 0w0), CodeZero, mkEval(#load onExitFn level, onArgs))
            in
                val exitCode = rtEnvDec @ #dec onExitFn @ [mkNullDec optCallOnExit]
            end
        in
            mkEnv(prefixCode @ entryCode @ #dec bodyCode @ exitCode @ restoreState, #load bodyCode level)
        end

    type breakPoint = machineWord ref
 
    (* Create a local break point and check the global and local break points. *)
    fun breakPointCode(location, level, lex, mkAddr) =
        if not (getParameter debugTag (LEX.debugParams lex)) then ([], NONE)
        else
        let
            open ADDRESS RuntimeCalls
            (* Create a new breakpoint ref. *)
            val localBreakPoint = ref (toMachineWord 0w0)
            (* First check the global breakpoint. *)
            val threadId = mkEval(rtsFunction POLY_SYS_thread_self, [])
            val globalBpt =
                multipleUses(
                    mkEval(rtsFunction POLY_SYS_load_word, [threadId, threadIdBreakPoint]), fn () => mkAddr 1, level)
            (* Then the local breakpoint. *)
            val localBpt =
                multipleUses(
                    mkEval(rtsFunction POLY_SYS_load_word,
                        [mkConst(toMachineWord localBreakPoint), CodeZero]), fn () => mkAddr 1, level)
            val testCode =
                mkIf(
                    mkNot(mkTagTest(#load globalBpt level, 0w0, 0w0)), 
                    mkEval(#load globalBpt level, [mkConst(toMachineWord location)]),
                    mkEnv(
                        #dec localBpt,
                        mkIf(
                            mkTagTest(#load localBpt level, 0w0, 0w0),
                            CodeZero,
                            mkEval(#load globalBpt level, [mkConst(toMachineWord location)])
                        )
                    )
                )
        in
            (#dec globalBpt @ [mkNullDec testCode], SOME localBreakPoint)
        end

    fun setBreakPoint bpt NONE = bpt := ADDRESS.toMachineWord 0w0
    |   setBreakPoint bpt (SOME f) = bpt := ADDRESS.toMachineWord f

    structure Sharing =
    struct
        type types          = types
        type values         = values
        type machineWord    = machineWord
        type fixStatus      = fixStatus
        type structVals     = structVals
        type typeConstrSet  = typeConstrSet
        type signatures     = signatures
        type functors       = functors
        type locationProp   = locationProp
        type environEntry   = environEntry
        type typeId         = typeId
        type level          = level
        type lexan          = lexan
        type codeBinding    = codeBinding
        type codetree       = codetree
        type typeVarMap     = typeVarMap
        type breakPoint     = breakPoint
        type debuggerStatus = debuggerStatus
    end
end;
