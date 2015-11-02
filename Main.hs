{-# LANGUAGE RankNTypes #-}
module Main where

import Realization
import Realization.Common
import Realization.Monolithic
import qualified Realization.BlockWise as BlockWise
import qualified Realization.TRGen as TRGen
import qualified Realization.Lisp as LispP
--import qualified Realization.LispKarr as LispP
--import qualified Realization.Threaded as Threaded
import Options
import CTIGAR (check)
import PartialArgs

import System.IO
import System.Exit
import Control.Concurrent
import Control.Exception

main = do
  opts <- readOptions
  case opts of
   Left errs -> do
     mapM_ (hPutStrLn stderr) errs
     exitWith (ExitFailure (-1))
   Right (file,opts) -> getTransitionRelation file opts $ \st -> do
     tr <- case optTimeout opts of
            Nothing -> check st (optBackends opts) (optVerbosity opts) (optStats opts)
            Just to -> do
              mainThread <- myThreadId
              timeoutThread <- forkOS (threadDelay to >> throwTo mainThread (ExitFailure (-2)))
              res <- catch (do
                               res <- check st (optBackends opts) (optVerbosity opts) (optStats opts)
                               killThread timeoutThread
                               return (Just res)
                           )
                     (\ex -> case ex of
                       ExitFailure _ -> return Nothing)
              case res of
               Just tr -> return tr
               Nothing -> do
                 hPutStrLn stderr "Timeout"
                 exitWith (ExitFailure (-2))
     case tr of
      Right fp -> putStrLn "No bug found."
      Left tr' -> do
        putStrLn "Bug found:"
        mapM_ (\(step,inp) -> do
                  putStr "State: "
                  renderPartialState st
                    (unmaskValue (getUndefState st) step) >>= putStrLn
                  putStr "Input: "
                  renderPartialInput st
                    (unmaskValue (getUndefInput st) inp) >>= putStrLn
              ) tr'

getUndefState :: TransitionRelation tr => tr -> State tr
getUndefState _ = undefined

getUndefInput :: TransitionRelation tr => tr -> Input tr
getUndefInput _ = undefined

getTransitionRelation :: String -> Options
                         -> (forall mdl. TransitionRelation mdl => mdl -> IO a) -> IO a
getTransitionRelation file opts f = do
  case optEncoding opts of
   Monolithic -> do
     let ropts = RealizationOptions { useErrorState = True
                                    , exactPredecessors = False
                                    , optimize = optOptimizeTR opts
                                    , eliminateDiv = False
                                    , integerEncoding = EncInt
                                    , forceNondet = const False
                                    , useKarr = optKarr opts
                                    , extraPredicates = optExtraPredicates opts
                                    , verbosity = optVerbosity opts }
     (_,fun) <- getProgram (optDumpModule opts) (optOptimizeTR opts) (optFunction opts) file
     st <- getModel ropts fun
     f st
   {-Threaded -> do
     (mod,fun) <- getProgram (optDumpModule opts) (optOptimizeTR opts) (optFunction opts) file
     real <- Threaded.realizeProgram mod fun
     error "Threaded..."-}
   BlockWise -> do
     (_,fun) <- getProgram (optDumpModule opts) (optOptimizeTR opts) (optFunction opts) file
     st <- BlockWise.realizeFunction fun
     f st
   TRGen -> do
     trgen <- TRGen.readTRGen True file
     f trgen
   Lisp -> do
     program <- fmap LispP.parseLispProgram $
                withFile file ReadMode LispP.readLispFile
     --nprogram <- if optKarr opts
     --            then LispP.addKarrPredicates program
     --            else return program
     f program
