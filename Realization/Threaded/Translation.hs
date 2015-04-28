{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,ViewPatterns #-}
module Realization.Threaded.Translation where

import Gates
import Realization.Threaded
import Realization.Threaded.State
import Realization.Threaded.Value
import qualified Realization.Lisp.Value as L
import qualified Realization.Lisp as L

import Language.SMTLib2
import Language.SMTLib2.Internals
import LLVM.FFI

import Data.Fix
import qualified Data.AttoLisp as L
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Monad.State (evalStateT,get,put)
import Data.Traversable
import Prelude hiding (foldl,sequence,mapM,mapM_,concat)
import Data.Foldable
import qualified Data.Text as T
import Foreign.Ptr (Ptr)
import Data.Typeable
import System.IO.Unsafe

toLispProgram :: Realization (ProgramState,ProgramInput)
              -> IO L.LispProgram
toLispProgram real = do
  threadNames <- evalStateT (mapM (\_ -> do
                                      n <- get
                                      put (n+1)
                                      return $ "thread"++show n
                                  ) (threadStateDesc $ stateAnnotation real)) 1
  st1 <- foldlM (\mp blk -> do
                    name <- blockName blk
                    return $ Map.insert (T.append "main-" name) (L.boolType,Map.singleton "pc" (L.Symbol "true")) mp
                ) Map.empty (Map.keys $ latchBlockDesc $ mainStateDesc $ stateAnnotation real)
  st2 <- foldlM (\mp (thread,thSt) -> do
                    let tName = threadNames Map.! thread
                    foldlM (\mp blk -> do
                               name <- blockName blk
                               return $ Map.insert (T.append (T.pack $ tName++"-") name)
                                 (L.boolType,Map.singleton "pc" (L.Symbol "true")) mp
                           ) mp (Map.keys $ latchBlockDesc thSt)
                ) st1 (Map.toList $ threadStateDesc $ stateAnnotation real)
  st3 <- foldlM (\mp (instr,tp) -> do
                    name <- instrName instr
                    return $ Map.insert (T.append "main-" name)
                      (toLispType $ Singleton tp) mp
                ) st2 (Map.toList $ latchValueDesc $ mainStateDesc $ stateAnnotation real)
  st4 <- foldlM (\mp (thread,thSt) -> do
                    let tName = threadNames Map.! thread
                    mp1 <- foldlM (\mp (instr,tp) -> do
                                      name <- instrName instr
                                      let name1 = T.append (T.pack $ tName++"-") name
                                      return $ Map.insert name1 (toLispType $ Singleton tp) mp
                                  ) mp (Map.toList $ latchValueDesc thSt)
                    mp2 <- case threadArgumentDesc thSt of
                      Nothing -> return mp1
                      Just (val,tp) -> do
                        name <- instrName val
                        let name1 = T.append (T.pack $ tName++"-") name
                        return $ Map.insert name1 (toLispType $ Singleton tp) mp1
                    return mp2
                ) st3 (Map.toList $ threadStateDesc $ stateAnnotation real)
  let inp1 = foldl (\mp thName
                    -> Map.insert (T.pack $ "step-"++thName) (L.boolType,Map.empty) mp
                   ) (Map.singleton "step-main" (L.boolType,Map.empty)) threadNames
  st5 <- foldlM (\mp (loc,tp) -> do
                    name <- memLocName loc
                    return $ Map.insert name (toLispAllocType tp) mp
                ) st4 (Map.toList $ memoryDesc $ stateAnnotation real)
  st6 <- foldlM (\mp thread -> do
                    let tName = threadNames Map.! thread
                    return $ Map.insert (T.pack $ "run-"++tName) (L.boolType,Map.empty) mp
                ) st5 (Map.keys $ threadStateDesc $ stateAnnotation real)
  inp2 <- foldlM (\mp (instr,tp) -> do
                     name <- instrName instr
                     let name1 = T.append "main-inp-" name
                     return $ Map.insert name1 (toLispType $ Singleton tp) mp
                 ) inp1 (Map.toList $ nondetTypes $ mainInputDesc $ inputAnnotation real)
  inp3 <- foldlM (\mp (thread,thInp) -> do
                     let tName = threadNames Map.! thread
                     foldlM (\mp (instr,tp) -> do
                               name <- instrName instr
                               let name1 = T.append (T.pack $ tName++"-inp-") name
                               return $ Map.insert name1 (toLispType $ Singleton tp) mp
                           ) mp (Map.toList $ nondetTypes thInp)
                 ) inp2 (Map.toList $ threadInputDesc $ inputAnnotation real)
  input <- makeProgramInput threadNames real
  let gateTrans = Map.foldlWithKey
                  (\gts tp (_,AnyGateArray arr)
                   -> Map.foldlWithKey
                      (\gts (GateExpr n) gate
                       -> translateGate n gate gts
                      ) gts arr
                  ) (GateTranslation Map.empty Map.empty Map.empty) (gateMp real)
      gates :: Map T.Text (L.LispType,L.LispVar)
      gates = Map.foldlWithKey
              (\gts tp (_,AnyGateArray arr)
               -> Map.foldlWithKey
                  (\gts (GateExpr n) (gate::Gate (ProgramState,ProgramInput) outp)
                   -> let expr = gateTransfer gate input
                          sort = getSort (undefined::outp) (gateAnnotation gate)
                      in L.withIndexableSort (undefined::SMTExpr Integer) sort $
                         \(_::t) -> case cast $ toLispExpr gateTrans expr of
                         Just expr' -> Map.insert ((nameMapping gateTrans) Map.! (tp,n))
                                       (L.LispType 0 (L.Singleton sort),
                                        L.LispConstr $ L.LispValue (L.Size [])
                                        (L.Singleton (L.Val (expr'::SMTExpr t)))) gts
                  ) gts arr
              ) Map.empty (gateMp real)
  nxt1 <- foldlM (\mp blk -> do
                     name <- blockName blk
                     let name1 = T.append "main-" name
                     cond0 <- if snd blk==0
                              then return []
                              else case Map.lookup (Nothing,fst blk,snd blk) (yieldEdges real) of
                                    Just edge -> return [ toLispExpr gateTrans $
                                                          edgeActivation cond input
                                                        | cond <- edgeConditions edge ]
                     let cond1 = case Map.lookup (Nothing,fst blk,snd blk) (edges real) of
                           Nothing -> []
                           Just edge -> [ toLispExpr gateTrans $
                                          edgeActivation cond input
                                        | cond <- edgeConditions edge ]
                         step = InternalObj (L.LispVarAccess
                                             (L.NamedVar "step-main" L.Input L.boolType)
                                             [] []) ()
                         old = InternalObj (L.LispVarAccess
                                            (L.NamedVar name1 L.State L.boolType)
                                            [] []) ()
                     return $ Map.insert name1 (L.LispConstr $
                                                L.LispValue (L.Size []) $
                                                L.Singleton $
                                                L.Val $ case cond0++cond1 of
                                                 [] -> (not' step) .&&. old
                                                 [x] -> ite step x old
                                                 xs -> ite step (app or' xs) old) mp
                 ) Map.empty (Map.keys $ latchBlockDesc $ mainStateDesc $ stateAnnotation real)
  nxt2 <- foldlM (\mp (thread,thSt) -> do
                     let tName = threadNames Map.! thread
                     foldlM (\mp blk -> do
                               name <- blockName blk
                               let name1 = T.append (T.pack $ tName++"-") name
                               cond0 <- if snd blk==0
                                        then return []
                                        else case Map.lookup (Just thread,fst blk,snd blk) (yieldEdges real) of
                                              Just edge -> return [ toLispExpr gateTrans $
                                                                    edgeActivation cond input
                                                                  | cond <- edgeConditions edge ]
                               let cond1 = case Map.lookup (Just thread,fst blk,snd blk) (edges real) of
                                     Nothing -> []
                                     Just edge -> [ toLispExpr gateTrans $
                                                    edgeActivation cond input
                                                  | cond <- edgeConditions edge ]
                                   step = InternalObj (L.LispVarAccess
                                                       (L.NamedVar (T.pack $ "step-"++tName)
                                                        L.Input L.boolType)
                                                       [] []) ()
                                   old = InternalObj (L.LispVarAccess
                                                      (L.NamedVar name1 L.State L.boolType)
                                                      [] []) ()
                               return $ Map.insert name1
                                 (L.LispConstr $
                                  L.LispValue (L.Size []) $
                                  L.Singleton $
                                  L.Val $ case cond0++cond1 of
                                   [] -> (not' step) .&&. old
                                   [x] -> ite step x old
                                   xs -> ite step (app or' xs) old) mp
                           ) mp (Map.keys $ latchBlockDesc thSt)
                 ) nxt1 (Map.toList $ threadStateDesc $ stateAnnotation real)
  let outValues = outputValues real
  nxt3 <- foldlM (\mp ((th,instr),val) -> do
                     name <- instrName instr
                     let tName = case th of
                           Nothing -> "main-"
                           Just th' -> T.pack $ (threadNames Map.! th')++"-"
                         name1 = T.append tName name
                         expr = val input
                         tDesc = case th of
                           Nothing -> mainStateDesc $ stateAnnotation real
                           Just th -> (threadStateDesc $ stateAnnotation real) Map.! th
                         tp = (latchValueDesc tDesc) Map.! instr
                     return $ Map.insert name1 (toLispExprs gateTrans (Singleton tp) (Singleton expr)) mp
                 ) nxt2 (Map.toList outValues)
  nxt4 <- foldlM (\mp (loc,val) -> do
                     let tp = (memoryDesc $ stateAnnotation real) Map.! loc
                     name <- memLocName loc
                     return $ Map.insert name (toLispAllocExpr gateTrans tp val) mp
                 ) nxt3 (Map.toList $ outputMem real input)
  nxt5 <- foldlM (\mp th -> do
                     let name = threadNames Map.! th
                         conds = case Map.lookup th (spawnEvents real) of
                           Nothing -> []
                           Just xs -> [ x input | (x,_) <- xs ]
                         old = InternalObj (L.LispVarAccess
                                            (L.NamedVar (T.pack $ "run-"++name)
                                             L.State L.boolType) [] []) ()
                         act = case conds of
                           [] -> old
                           [x] -> x .||. old
                           xs -> (app and' xs) .||. old
                         term = case Map.lookup th (termEvents real) of
                           Nothing -> act
                           Just [x] -> act .&&. (not' (x input))
                           Just xs -> act .&&. (not' $ app and' [ x input | x <- xs])
                     return $ Map.insert (T.pack $ "run-"++name)
                       (L.LispConstr $
                        L.LispValue (L.Size []) $
                        L.Singleton $
                        L.Val $ toLispExpr gateTrans term) mp
                 ) nxt4 (Map.keys $ threadStateDesc $ stateAnnotation real)
  nxt6 <- foldlM (\mp (th,thD) -> case threadArgumentDesc thD of
                   Nothing -> return mp
                   Just (arg,tp) -> do
                     iName <- instrName arg
                     let thName = threadNames Map.! th
                         name = T.append (T.pack $ thName++"-") iName
                         old = L.NamedVar name L.State (fst $ toLispType (Singleton tp))
                         acts = case Map.lookup th (spawnEvents real) of
                           Just l -> l
                           Nothing -> []
                     return $ Map.insert name
                       (foldl (\cur (act,Just instrV)
                                -> L.LispITE (toLispExpr gateTrans (act input))
                                   (toLispExprs gateTrans (Singleton tp)
                                    (Singleton $ symbolicValue instrV input)) cur
                              ) old acts) mp
                 ) nxt5 (Map.toList $ threadStateDesc $ stateAnnotation real)                     
  init1' <- mapM (\(glob,val) -> do
                    name <- memLocName (Right glob)
                    let tp = (memoryDesc (stateAnnotation real)) Map.! (Right glob)
                        var1 = toLispAllocExpr gateTrans tp val
                    return (name,var1)
                 ) (Map.toList $ memoryInit real)
  init2' <- mapM (\th -> do
                     let name = threadNames Map.! th
                     return (T.pack $ "run-"++name,
                             L.LispConstr (L.LispValue (L.Size [])
                                           (L.Singleton (L.Val (constant False)))))
                 ) (Map.keys $ threadStateDesc $ stateAnnotation real)
  init3' <- mapM (\blk -> do
                     name <- blockName blk
                     return (T.append "main-" name,
                             L.LispConstr (L.LispValue (L.Size [])
                                           (L.Singleton (L.Val (constant $ blk==(mainBlock real,0))))))
                 ) (Map.keys $ latchBlockDesc $ mainStateDesc $ stateAnnotation real)
  init4' <- mapM (\(th,blk) -> do
                     let tName = threadNames Map.! th
                     mapM (\blk' -> do
                              name <- blockName blk'
                              return (T.append (T.pack $ tName++"-") name,
                                      L.LispConstr (L.LispValue (L.Size [])
                                                    (L.Singleton (L.Val (constant $ blk'==(blk,0))))))
                          ) (Map.keys $ latchBlockDesc $
                             (threadStateDesc $ stateAnnotation real) Map.! th)
                ) (Map.toList $ threadBlocks real)
  let asserts = fmap (\cond -> toLispExpr gateTrans (cond input)) (assertions real)
  inv1 <- do
    blks <- mapM (\blk -> do
                     name <- blockName blk
                     return $ InternalObj (L.LispVarAccess
                                           (L.NamedVar (T.append "main-" name)
                                            L.State L.boolType) [] []) ()
                 ) (Map.keys $ latchBlockDesc $ mainStateDesc $ stateAnnotation real)
    return $ app L.exactlyOne blks
  inv2 <- mapM (\(th,thSt) -> do
                   let tName = threadNames Map.! th
                   blks <- mapM (\blk -> do
                                    name <- blockName blk
                                    return $ InternalObj
                                      (L.LispVarAccess
                                       (L.NamedVar (T.append (T.pack $ tName++"-") name)
                                        L.State L.boolType) [] []) ()
                                ) (Map.keys $ latchBlockDesc thSt)
                   return $ app L.exactlyOne blks
               ) (Map.toList $ threadStateDesc $ stateAnnotation real)
  let inv3 = app L.exactlyOne $
             (InternalObj (L.LispVarAccess
                           (L.NamedVar "step-main" L.Input L.boolType) [] []) ()):
             fmap (\th -> let tName = threadNames Map.! th
                          in InternalObj (L.LispVarAccess
                                          (L.NamedVar (T.pack $ "step-"++tName)
                                           L.Input L.boolType) [] []) ()
                  ) (Map.keys $ threadStateDesc $ stateAnnotation real)
  return $ L.LispProgram { L.programAnnotation = Map.empty
                         , L.programDataTypes = emptyDataTypeInfo
                         , L.programState = st6
                         , L.programInput = inp3
                         , L.programGates = gates
                         , L.programNext = nxt6
                         , L.programProperty = asserts
                         , L.programInit = Map.fromList (init1'++init2'++init3'++concat init4')
                         , L.programInvariant = [inv3] -- inv1:inv3:inv2
                         , L.programAssumption = []
                         , L.programPredicates = [] }

toLispType :: Struct SymType -> (L.LispType,L.Annotation)
toLispType tp = (L.LispType 0 (toLispType' tp),Map.empty)

toLispType' :: Struct SymType -> L.LispStruct Sort
toLispType' (Singleton TpBool) = L.Singleton (Fix BoolSort)
toLispType' (Singleton TpInt) = L.Singleton (Fix IntSort)
toLispType' (Singleton (TpPtr dest _))
  = L.Struct [ L.Struct $
               L.Singleton (Fix BoolSort):
               [ L.Singleton (Fix IntSort)
               | DynamicAccess <- offsetPattern dest ]
             | dest <- Map.keys dest ]
toLispType' (Singleton (TpThreadId ths)) = L.Struct [ L.Singleton (Fix BoolSort)
                                                    | th <- Map.keys ths ]
toLispType' (Struct tps) = L.Struct $ fmap toLispType' tps

toLispAllocType :: AllocType -> (L.LispType,L.Annotation)
toLispAllocType (TpStatic num tp) = (L.LispType 0 (L.Struct [ toLispType' tp
                                                            | n <- [0..num-1]]),Map.empty)
toLispAllocType (TpDynamic tp) = (L.LispType 1 (toLispType' tp),Map.empty)

blockName :: (Ptr BasicBlock,Int) -> IO T.Text
blockName (blk,sblk) = do
  blkName <- getNameString blk
  if sblk==0
    then return $ T.pack blkName
    else return $ T.pack (blkName++"."++show sblk)

threadName :: Ptr CallInst -> IO T.Text
threadName call = do
  thFun <- getOperand call 2
  name <- getNameString thFun
  return $ T.pack name

instrName :: ValueC v => Ptr v -> IO T.Text
instrName instr = do
  name <- getNameString instr
  return $ T.pack name

memLocName :: MemoryLoc -> IO T.Text
memLocName (Left alloc) = do
  name <- getNameString alloc
  fun <- instructionGetParent alloc >>= basicBlockGetParent >>= getNameString
  return $ T.pack $ "alloc-"++fun++"-"++name
memLocName (Right glob) = do
  name <- getNameString glob
  return $ T.pack name

data GateTranslation = GateTranslation { nameMapping :: Map (TypeRep,Int) T.Text
                                       , reverseNameMapping :: Map T.Text (TypeRep,Int)
                                       , nameUsage :: Map String Int }

translateGate :: Typeable outp => Int -> Gate inp outp -> GateTranslation -> GateTranslation
translateGate gtN (gt::Gate inp outp) trans
  = trans { nameMapping = Map.insert (tp,gtN) tName
                          (nameMapping trans)
          , reverseNameMapping = Map.insert tName (tp,gtN)
                                 (reverseNameMapping trans)
          , nameUsage = Map.insert name (usage+1)
                        (nameUsage trans)
          }
  where
    name = case gateName gt of
      Nothing -> "gt"
      Just n -> n
    rname = "gt-"++if usage==0
                   then name
                   else name++"$"++show usage
    tName = T.pack rname
    tp = typeOf (undefined::outp)
    usage = case Map.lookup name (nameUsage trans) of
      Nothing -> 0
      Just n -> n

toLispExpr :: GateTranslation -> SMTExpr a -> SMTExpr a
toLispExpr trans (InternalObj (cast -> Just (GateExpr n)) ann::SMTExpr a)
  = case Map.lookup (typeOf (undefined::a),n) (nameMapping trans) of
  Just r -> InternalObj (L.LispVarAccess (L.NamedVar r L.Gate
                                          (L.LispType 0 (L.Singleton (getSort (undefined::a) ann)))) [] []) ann
toLispExpr trans (App fun arg)
  = App fun (snd $ foldExprsId (\_ expr _ -> ((),toLispExpr trans expr)
                               ) () arg (extractArgAnnotation arg))
toLispExpr _ e = e

makeProgramInput :: Map (Ptr CallInst) String -> Realization (ProgramState,ProgramInput)
                 -> IO (ProgramState,ProgramInput)
makeProgramInput threadNames real = do
  mainBlocks <- sequence $ Map.mapWithKey
                (\blk _ -> do
                    name <- blockName blk
                    return $ InternalObj (L.LispVarAccess
                                          (L.NamedVar (T.append "main-" name) L.State L.boolType)
                                          [] []
                                         ) ()
                ) (latchBlockDesc $ mainStateDesc $ stateAnnotation real)
  mainInstrs <- sequence $ Map.mapWithKey
                (\instr tp -> do
                    name <- instrName instr
                    return $ makeVar (L.NamedVar (T.append "main-" name) L.State
                                      (L.LispType 0 (toLispType' (Singleton tp)))) tp
                ) (latchValueDesc $ mainStateDesc $ stateAnnotation real)
  threads <- sequence $ Map.mapWithKey
             (\th thd -> do
                 let thName = threadNames Map.! th
                     run = InternalObj (L.LispVarAccess
                                        (L.NamedVar (T.pack $ "run-"++thName) L.State L.boolType)
                                        [] []) ()
                 blocks <- sequence $ Map.mapWithKey
                           (\blk _ -> do
                               name <- blockName blk
                               let name' = T.append (T.pack $ thName++"-") name
                               return $ InternalObj (L.LispVarAccess
                                                     (L.NamedVar name' L.State L.boolType)
                                                     [] []) ()
                           ) (latchBlockDesc thd)
                 instrs <- sequence $ Map.mapWithKey
                           (\instr tp -> do
                               name <- instrName instr
                               let name' = T.append (T.pack $ thName++"-") name
                               return $ makeVar (L.NamedVar name' L.State
                                                 (L.LispType 0
                                                  (toLispType' (Singleton tp)))) tp
                           ) (latchValueDesc thd)
                 arg <- case threadArgumentDesc thd of
                   Nothing -> return Nothing
                   Just (val,tp) -> do
                     name <- instrName val
                     let name' = T.append (T.pack $ thName++"-") name
                     return (Just (val,makeVar (L.NamedVar name' L.State
                                                (L.LispType 0 (toLispType'
                                                               (Singleton tp)))) tp))
                 return (run,ThreadState { latchBlocks = blocks
                                         , latchValues = instrs
                                         , threadArgument = arg })
             ) (threadStateDesc $ stateAnnotation real)
  mem <- sequence $ Map.mapWithKey
         (\loc tp -> do
             name <- memLocName loc
             return $ makeAllocVar name L.State tp
         ) (memoryDesc $ stateAnnotation real)
  mainNondet <- sequence $ Map.mapWithKey
                (\instr tp -> do
                    name <- instrName instr
                    return $ makeVar (L.NamedVar (T.append "main-inp-" name) L.Input
                                      (L.LispType 0 (toLispType' (Singleton tp)))) tp
                ) (nondetTypes $ mainInputDesc $ inputAnnotation real)
  thInps <- sequence $ Map.mapWithKey
            (\th thd -> do
                let thName = threadNames Map.! th
                nondet <- sequence $ Map.mapWithKey
                          (\instr tp -> do
                              name <- instrName instr
                              return $ makeVar
                                (L.NamedVar (T.append (T.pack $ thName++"-inp-") name) L.Input
                                 (L.LispType 0 (toLispType' (Singleton tp)))) tp
                          ) (nondetTypes thd)
                return ThreadInput { step = InternalObj (L.LispVarAccess
                                                         (L.NamedVar (T.pack $ "step-"++thName)
                                                          L.Input L.boolType)
                                                         [] []) ()
                                   , nondets = nondet }
            ) (threadInputDesc $ inputAnnotation real)
  return (ProgramState { mainState = ThreadState { latchBlocks = mainBlocks
                                                 , latchValues = mainInstrs
                                                 , threadArgument = Nothing }
                       , threadState = threads
                       , memory = mem },
          ProgramInput { mainInput = ThreadInput { step = InternalObj
                                                          (L.LispVarAccess
                                                           (L.NamedVar "step-main" L.Input
                                                            L.boolType)
                                                           [] []) ()
                                                 , nondets = mainNondet }
                       , threadInput = thInps })

makeVar :: L.LispVar -> SymType -> SymVal
makeVar = makeVar' []

makeVar' :: [Integer] -> L.LispVar -> SymType -> SymVal
makeVar' idx var TpBool
  = ValBool $ InternalObj (L.LispVarAccess var idx []) ()
makeVar' idx var TpInt
  = ValInt $ InternalObj (L.LispVarAccess var idx []) ()
makeVar' idx var (TpPtr locs ptp)
  = ValPtr (snd $ Map.mapAccumWithKey
            (\i loc () -> (i+1,
                           (InternalObj (L.LispVarAccess
                                         var
                                         (idx++[i,0]) []) (),
                            [InternalObj (L.LispVarAccess
                                          var
                                          (idx++[i,j]) []) ()
                            | (j,_) <- zip [1..] [ () | DynamicAccess <- offsetPattern loc ] ]))
            ) 0 locs) ptp
makeVar' idx var (TpThreadId ths)
  = ValThreadId $ snd $ Map.mapAccum
    (\i () -> (i+1,InternalObj (L.LispVarAccess
                                var
                                (idx++[i]) []) ())) 0 ths

makeAllocVar :: T.Text -> L.LispVarCat -> AllocType -> AllocVal
makeAllocVar name cat tp@(TpStatic n tps)
  = ValStatic [ makeStruct [i] tps | i <- [0..n-1] ]
  where
    var = L.NamedVar name cat (fst $ toLispAllocType tp)
    makeStruct idx (Singleton tp) = Singleton (makeVar' idx var tp)
    makeStruct idx (Struct tps) = Struct [ makeStruct (idx++[i]) tp
                                         | (i,tp) <- zip [0..] tps ]
makeAllocVar name cat rtp@(TpDynamic tp)
  = ValDynamic (makeStruct [] tp) (InternalObj (L.LispSizeAccess
                                                var
                                                []) ())
  where
    var = L.NamedVar name cat (fst $ toLispAllocType rtp)
    makeStruct idx (Singleton TpBool)
      = Singleton $ ArrBool (InternalObj (L.LispVarAccess
                                          var
                                          idx []) ((),()))
    makeStruct idx (Singleton TpInt)
      = Singleton $ ArrInt (InternalObj (L.LispVarAccess
                                         var
                                         idx []) ((),()))
    makeStruct idx (Struct tps)
      = Struct [ makeStruct (idx++[i]) tp
               | (i,tp) <- zip [0..] tps ]

toLispExprs :: GateTranslation -> Struct SymType -> Struct SymVal -> L.LispVar
toLispExprs trans tp val = L.LispConstr $ toLispValue trans tp val

toLispValue :: GateTranslation -> Struct SymType -> Struct SymVal -> L.LispValue
toLispValue trans tp val = L.LispValue (L.Size []) (toLispExprs' trans tp val)

toLispExprs' :: GateTranslation -> Struct SymType -> Struct SymVal -> L.LispStruct L.LispVal
toLispExprs' trans (Singleton TpBool) (Singleton (ValBool x))
  = L.Singleton (L.Val $ toLispExpr trans x)
toLispExprs' trans (Singleton TpInt) (Singleton (ValInt x))
  = L.Singleton (L.Val $ toLispExpr trans x)
toLispExprs' trans (Singleton (TpPtr locs _)) (Singleton (ValPtr trgs _))
  = if Map.null diff
    then L.Struct [ L.Struct (L.Singleton (L.Val $ toLispExpr trans cond):
                              [ L.Singleton (L.Val $ toLispExpr trans i) | i <- idx ])
                  | (trg,pat) <- Map.toList locs
                  , let (cond,idx) = case Map.lookup trg trgs of
                          Just r -> r
                          Nothing -> (constant False,[]{-[ constant 0
                                                         | DynamicAccess <- pat ]-}) ]
    else unsafePerformIO $ do
      putStrLn "Allowed:"
      mapM (\ptr -> do
               name <- memLocName (memoryLoc ptr)
               putStrLn $ (T.unpack name)++" "++show (offsetPattern ptr)
           ) (Map.keys locs)
      putStrLn "Forbidden:"
      mapM (\ptr -> do
               name <- memLocName (memoryLoc ptr)
               putStrLn $ (T.unpack name)++" "++show (offsetPattern ptr)
           ) (Map.keys diff)
      error $ "Incomplete: Pointer pointing to unexpected location"
  where
    diff = Map.difference trgs locs
toLispExprs' trans (Singleton (TpThreadId trgs)) (Singleton (ValThreadId ths))
  = L.Struct [ L.Singleton (L.Val $ toLispExpr trans cond)
             | trg <- Map.keys trgs
             , let cond = case Map.lookup trg ths of
                     Just c -> c
                     Nothing -> constant False ]
toLispExprs' trans (Struct tps) (Struct fs)
  = L.Struct (zipWith (toLispExprs' trans) tps fs)

toLispAllocExpr :: GateTranslation -> AllocType -> AllocVal -> L.LispVar
toLispAllocExpr trans (TpStatic n tp) (ValStatic vals)
  = L.LispConstr $ L.LispValue (L.Size [])
    (L.Struct $ fmap (toLispExprs' trans tp) vals)
toLispAllocExpr trans (TpDynamic tp) (ValDynamic vals sz)
  = L.LispConstr $ L.LispValue (L.Size [L.SizeElement $ toLispExpr trans sz])
    (toLispArray vals)
  where
    toLispArray (Singleton (ArrBool arr)) = L.Singleton $ L.Val (toLispExpr trans arr)
    toLispArray (Singleton (ArrInt arr)) = L.Singleton $ L.Val (toLispExpr trans arr)
    toLispArray (Singleton (ArrPtr arrs _))
      = L.Struct [ L.Struct (L.Singleton (L.Val $ toLispExpr trans elArr):
                             [ L.Singleton (L.Val $ toLispExpr trans idxArr)
                             | idxArr <- idxArrs ])
                 | (elArr,idxArrs) <- Map.elems arrs ]
    toLispArray (Singleton (ArrThreadId arrs))
      = L.Struct [ L.Singleton (L.Val $ toLispExpr trans arr)
                 | arr <- Map.elems arrs ]
    toLispArray (Struct xs) = L.Struct (fmap toLispArray xs)
