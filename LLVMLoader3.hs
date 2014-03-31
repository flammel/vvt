{-# LANGUAGE ScopedTypeVariables,ViewPatterns,GADTs,PackageImports,RankNTypes #-}
module LLVMLoader3 where

import Gates
import Affine
import ExprPreprocess
import Karr

import Language.SMTLib2
import Language.SMTLib2.Internals hiding (Value)
import Language.SMTLib2.Pipe
import Language.SMTLib2.Internals.Optimize
import Language.SMTLib2.Internals.Instances (quantify,dequantify)
import Language.SMTLib2.Debug
import LLVM.FFI

import Prelude hiding (foldl,mapM_,mapM)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.IntMap as IMap
import Foreign.Ptr
import Foreign.C.String
import Data.Foldable
import Data.Traversable
import System.Environment (getArgs)
import Foreign.Marshal.Array
import "mtl" Control.Monad.State (runStateT,get,put,lift)
import "mtl" Control.Monad.Trans (liftIO)
import Data.Typeable (cast)
import qualified Data.Vector as Vec
import Data.Maybe (catMaybes)
import Debug.Trace
import Data.Graph.Inductive.Graphviz

import Realization

traceThis :: Show a => a -> a
traceThis = traceWith show

traceWith :: (a -> String) -> a -> a
traceWith f x = trace (f x) x

declareOutputActs :: RealizationSt -> RealizedGates -> LLVMInput
                     -> SMT (Map (Ptr BasicBlock) (Map (Ptr BasicBlock) (SMTExpr Bool))
                            ,RealizedGates)
declareOutputActs st real inp
  = runStateT (Map.traverseWithKey
               (\trg el
                -> Map.traverseWithKey
                   (\src act -> do
                       real <- get
                       (expr,nreal) <- lift $ declareGate (act inp) real (gates st) inp
                       put nreal
                       return expr
                   ) el
               ) (backwardEdges st)
              ) real

getOutput :: RealizationSt -> LLVMInput -> LLVMOutput
getOutput st inp
  = let acts = fmap (fmap (\act -> translateGateExpr (act inp) (gates st) inp)) (backwardEdges st)
        latchs = fmap (\(UntypedExpr xs)
                       -> UntypedExpr $ translateGateExpr xs (gates st) inp) $
                 Map.intersection (prevInstrs st) (latchInstrs st)
    in (acts,latchs)

declareOutputInstrs :: RealizationSt -> RealizedGates -> LLVMInput
                       -> SMT (Map (Ptr Instruction) UntypedExpr
                              ,RealizedGates)
declareOutputInstrs st real inp
  = runStateT (Map.traverseWithKey
               (\instr (UntypedExpr val) -> do
                   real <- get
                   (expr,nreal) <- lift $ declareGate val real (gates st) inp
                   put nreal
                   return (UntypedExpr expr)) (Map.intersection (prevInstrs st) (latchInstrs st))
              ) real

declareAssertions :: RealizationSt -> RealizedGates -> LLVMInput
                     -> SMT ([SMTExpr Bool]
                            ,RealizedGates)
declareAssertions st real inp
  = runStateT (traverse (\ass -> do
                            real <- get
                            (expr,nreal) <- lift $ declareGate (ass inp) real (gates st) inp
                            put nreal
                            return expr
                        ) (assertions st)
              ) real

declareAssumptions :: RealizationSt -> RealizedGates -> LLVMInput
                     -> SMT ([SMTExpr Bool]
                            ,RealizedGates)
declareAssumptions st real inp
  = runStateT (traverse (\ass -> do
                            real <- get
                            (expr,nreal) <- lift $ declareGate (ass inp) real (gates st) inp
                            put nreal
                            return expr
                        ) (assumptions st)
              ) real

allLatchBlockAssigns :: RealizationSt
                        -> [(Ptr BasicBlock,Ptr BasicBlock,
                             Map (Ptr BasicBlock) (Map (Ptr BasicBlock) (SMTExpr Bool)))]
allLatchBlockAssigns st
  = [ (src,trg,Map.mapWithKey
               (\trg'
                -> Map.mapWithKey
                   (\src' () -> constant $ trg==trg' && src==src')
               ) (latchBlks st))
    | (trg,srcs) <- Map.toList (latchBlks st)
    , (src,()) <- Map.toList srcs ]

getKarr :: RealizationSt -> Map (Ptr BasicBlock) (Map (Ptr BasicBlock) [ValueMap -> SMTExpr Bool])
getKarr st
  = trace (graphviz' (renderKarrTrans init_karr)) $
    fmap (fmap (\n -> let diag = traceWith (\diag' -> show n++": "++show diag') $ (karrNodes final_karr) IMap.! n
                          pvecs = traceThis $ extractPredicateVec diag
                      in [ \vals -> (constant c) .==. (case catMaybes [ case f of
                                                                           0 -> Nothing
                                                                           1 -> Just expr
                                                                           -1 -> Just $ app neg expr
                                                                           _ -> Just $ (constant f) * expr
                                                                      | (i,f) <- zip [0..] facs
                                                                      , let expr = castUntypedExpr $ vals Map.! (rev_mp Map.! i)
                                                                      ] of
                                                         [] -> constant 0
                                                         [x] -> x
                                                         xs -> app plus xs)
                         | pvec <- pvecs
                         , let c:facs = Vec.toList pvec ])) node_mp
  where
    final_karr = finishKarr init_karr
    init_karr = initKarr sz
                ((node_mp Map.! (initBlk st)) Map.! nullPtr)
                (\from to -> (trans_mp Map.! from) Map.! to)
                (\from -> case Map.lookup from trans_mp of
                    Nothing -> []
                    Just mp -> Map.keys mp)
    (sz_vals,int_vals,inp_vals,rev_mp)
      = Map.foldlWithKey
        (\(n,imp,amp,tmp) instr (ProxyArg (u::a) ann)
         -> case cast u of
           Just (_::Integer)
             -> (n+1,Map.insert instr n imp,
                 Map.insert instr (UntypedExpr (Var n ann::SMTExpr a)) amp,
                 Map.insert n instr tmp)
           Nothing -> (n,imp,
                       Map.insert instr (UntypedExpr (InternalObj () ann::SMTExpr a)) amp,
                       tmp)
        ) (0,Map.empty,Map.empty,Map.empty) (latchInstrs st)
    output = \acts (inps,latchs) -> getOutput st (acts,inps,latchs)
    transitions = [ (src,trg,trans5)
                  | (src,trg,acts) <- allLatchBlockAssigns st
                  , let (used,_,trans1) = quantify [(0::Integer)..] (inputInstrs st,latchInstrs st) (output acts)
                  , (_,trans2) <- removeArgGuards trans1
                  , let trans3 = dequantify used (inputInstrs st,latchInstrs st) trans2
                        trans4 = \inps -> trans3 (inps::ValueMap,inp_vals)
                  , trans5 <- removeInputs (inputInstrs st) (latchBlks st,latchInstrs st) trans4
                  ]
    (sz,node_mp) = Map.mapAccum
                   (Map.mapAccum (\n _ -> (n+1,n))) 0 (latchBlks st)
    trans_mp = foldl (\cmp (src,trg,(act_latch,var_latch))
                       -> let from_nd = (node_mp Map.! trg) Map.! src
                              tos = [ (to_src,to_trg)
                                    | (to_trg,to_trgs) <- Map.toList act_latch
                                    , (to_src,cond) <- Map.toList to_trgs
                                    , cond /= constant False ]
                              vals = mapM (\(instr,n) -> do
                                              res <- affineFromExpr $ castUntypedExpr $
                                                     var_latch Map.! instr
                                              return (n,res::AffineExpr Integer)
                                          ) (Map.toList int_vals)
                          in case vals of
                            Nothing -> cmp
                            Just vals'
                              -> let mat = Vec.fromList $
                                           [ Vec.generate (fromIntegral sz_vals)
                                             (\i' -> case Map.lookup (fromIntegral i') (affineFactors aff) of
                                                 Nothing -> 0
                                                 Just x -> x)
                                           | (i,aff) <- vals' ]
                                     vec = Vec.fromList
                                           [ affineConstant aff
                                           | (i,aff) <- vals' ]
                                     suc = foldl (\cmp (to_src,to_trg)
                                                   -> let rto = (node_mp Map.! to_trg) Map.! to_src
                                                      in Map.insertWith (++) rto [(mat,vec)] cmp
                                                 ) Map.empty tos
                                 in Map.insertWith (Map.unionWith (++)) from_nd suc cmp
                     ) Map.empty transitions

main = do
  [mod,entry] <- getArgs
  fun <- getProgram entry mod
  st <- realizeFunction fun
  pipe <- createSMTPipe "z3" ["-smt2","-in"]
  withSMTBackend (debugBackend $ optimizeBackend pipe)
    (do
        comment "activation latches:"
        inp_gates <- Map.traverseWithKey
                     (\trg
                      -> Map.traverseWithKey
                         (\src _
                          -> do
                            trg' <- liftIO $ getNameString trg
                            src' <- if src==nullPtr
                                    then return ""
                                    else liftIO $ getNameString src
                            varNamed (src'++"."++trg'))) (latchBlks st)
        comment "inputs:"
        inp_inps <- Map.traverseWithKey
                    (\instr (ProxyArg (_::a) ann) -> do
                        name <- liftIO $ getNameString instr
                        res <- varNamedAnn (name++"_") ann
                        return (UntypedExpr (res::SMTExpr a))
                    ) (inputInstrs st)
        comment "variable latches:"
        inp_vals <- Map.traverseWithKey
                    (\instr (ProxyArg (_::a) ann) -> do
                        name <- liftIO $ getNameString instr
                        res <- varNamedAnn (name++"_") ann
                        return (UntypedExpr (res::SMTExpr a))
                    ) (latchInstrs st)
        comment "gates:"
        let inps = (inp_gates,inp_inps,inp_vals)
        (gates,real0) <- declareOutputActs st Map.empty inps
        (vals,real1) <- declareOutputInstrs st real0 inps
        (asserts,real2) <- declareAssertions st real1 inps
        (assumes,real3) <- declareAssumptions st real2 inps
        mapM_ (\(trg,jumps) -> do
                  trg' <- liftIO $ getNameString trg
                  comment $ "To "++trg'++":"
                  mapM_ (\(src,act) -> do
                            src' <- if src==nullPtr
                                    then return "[init]"
                                    else liftIO $ getNameString src
                            act' <- renderExpr act
                            comment $ "  from "++src'++": "++act') (Map.toList jumps)
              ) (Map.toList gates)
        mapM_ (\(instr,UntypedExpr val) -> do
                  name <- liftIO $ getNameString instr
                  str <- renderExpr val
                  comment $ "Latch "++name++": "++str
              ) (Map.toList vals)
        mapM_ (\ass -> do
                  str <- renderExpr ass
                  comment $ "Assertion: "++str
              ) asserts
        mapM_ (\ass -> do
                  str <- renderExpr ass
                  comment $ "Assume: "++str
              ) assumes
        {-let output = \acts inps latchs -> getOutput st (acts,inps,latchs)
            transitions = [ (src,trg,trans')
                          | (src,trg,acts) <- allLatchBlockAssigns st
                          , trans <- removeInputs (inputInstrs st)
                                     (latchBlks st,latchInstrs st) (output acts) inp_vals
                          , (_,trans') <- removeArgGuards trans ]
        mapM_ (\(src,trg,(act_trans,latch_trans)) -> do
                  name <- liftIO $ if src==nullPtr
                                   then getNameString trg
                                   else (do
                                            src' <- getNameString src
                                            trg' <- getNameString trg
                                            return $ src'++"~>"++trg')
                  comment $ "From "++name
                  Map.traverseWithKey
                    (\ntrg nsrcs
                     -> Map.traverseWithKey
                        (\nsrc expr
                         -> do
                           name' <- liftIO $ if nsrc==nullPtr
                                             then getNameString ntrg
                                             else (do
                                                      nsrc' <- getNameString nsrc
                                                      ntrg' <- getNameString ntrg
                                                      return (nsrc'++"~>"++ntrg'))
                           expr' <- renderExpr expr
                           comment $ "  to "++name'++": "++expr'
                           return ()
                        ) nsrcs
                    ) act_trans
                  Map.traverseWithKey
                    (\instr (UntypedExpr expr) -> do
                        name <- liftIO $ getNameString instr
                        case cast expr >>= affineFromExpr of
                          Nothing -> do
                            res <- renderExpr expr
                            comment $ "Instr "++name++" not affine ("++res++")"
                          Just (aff::AffineExpr Integer) -> do
                            affExpr <- renderExpr (affineToExpr aff)
                            comment $ "Instr "++name++" = "++affExpr
                    ) latch_trans
              ) transitions-}
        comment $ "Karr analysis:"
        fixp <- mapM renderExpr [ fix inp_vals
                                | mp <- Map.elems (getKarr st)
                                , lst <- Map.elems mp
                                , fix <- lst ]
        comment $ show fixp
        comment $ "--------------"

        {-let (act_exprs,latch_exprs) = getOutput st inps
        mapM_ (\(instr,UntypedExpr val) -> case cast val of
                  Just (iexpr::SMTExpr Integer) -> affineFromExpr
                do
                  name <- liftIO $ getNameString instr
                  str <- renderExpr val
                  comment $ "Latch expr "++name++": "++str
              ) (Map.toList latch_exprs)-}
    )

data APass = forall p. PassC p => APass (IO (Ptr p))

passes :: String -> [APass]
passes entry
  = [APass createPromoteMemoryToRegisterPass
    ,APass createConstantPropagationPass
    ,APass createLoopSimplifyPass
    ,APass (do
               m <- newCString entry
               arr <- newArray [m]
               export_list <- newArrayRef arr 1
               --export_list <- newArrayRefEmpty
               createInternalizePass export_list)
    ,APass (createFunctionInliningPass 100)
    ,APass createCFGSimplificationPass
    ,APass createInstructionNamerPass]

applyOptimizations :: Ptr Module -> String -> IO ()
applyOptimizations mod entry = do
  pm <- newPassManager
  mapM (\(APass c) -> do
           pass <- c
           passManagerAdd pm pass) (passes entry)
  passManagerRun pm mod
  deletePassManager pm

getProgram :: String -> String -> IO (Ptr Function)
getProgram entry file = do
  Just buf <- getFileMemoryBufferSimple file
  diag <- newSMDiagnostic
  ctx <- newLLVMContext
  mod <- parseIR buf diag ctx
  applyOptimizations mod entry
  moduleDump mod
  moduleGetFunctionString mod entry
