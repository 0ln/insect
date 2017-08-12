-- | This module defines the interpreter for Insect.
module Insect.Interpreter
  ( MessageType(..)
  , Message(..)
  , runInsect
  ) where

import Prelude hiding (degree)

import Data.Array ((:), fromFoldable, singleton)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Foldable (foldMap, intercalate)
import Data.List (List, sortBy, filter, groupBy)
import Data.List.NonEmpty (NonEmptyList(..), head)
import Data.Maybe (Maybe(..))
import Data.NonEmpty (NonEmpty)
import Data.String (toLower)
import Data.StrMap (lookup, insert, toUnfoldable)
import Data.Tuple (fst, snd)
import Data.Traversable (traverse)

import Quantities (Quantity, ConversionError(..))
import Quantities as Q

import Insect.Language (Func(..), BinOp(..), Expression(..), Command(..),
                        Statement(..), Identifier)
import Insect.Environment (Environment, StorageType(..), StoredValue(..),
                           initialEnvironment)
import Insect.Functions (fromCelsius, fromFahrenheit, toCelsius, toFahrenheit)
import Insect.Format (Markup)
import Insect.Format as F
import Insect.PrettyPrint (pretty, prettyQuantity)

-- | Types of errors that may appear during evaluation.
data EvalError
  = QConversionError ConversionError
  | LookupError String
  | NumericalError
  | RedefinedConstantError Identifier

-- | A type synonym for error handling. A value of type `Expect Number` is
-- | expected to be a number but might also result in an evaluation error.
type Expect = Either EvalError

-- | Different kinds of messages that will be returned by the interpreter.
data MessageType = Value | ValueSet | Info | Error

-- | The output type of the interpreter.
data Message = Message MessageType Markup | MQuit | MClear

-- | Check if the numerical value of a quantity is finite, throw a
-- | `NumericalError` otherwise.
checkFinite ∷ Quantity → Expect Quantity
checkFinite q | Q.isFinite q = pure q
              | otherwise    = Left NumericalError

-- | Apply a mathematical function to a physical quantity.
applyFunction ∷ Func → NonEmpty List Quantity → Expect Quantity
applyFunction fn qs = lmap QConversionError $ (run fn) (head (NonEmptyList qs))
  where
    run Acos           = Q.acos
    run Acosh          = Q.acosh
    run Asin           = Q.asin
    run Asinh          = Q.asinh
    run Atan           = Q.atan
    run Atanh          = Q.atanh
    run Ceil           = Q.ceil
    run Cos            = Q.cos
    run Cosh           = Q.cosh
    run Exp            = Q.exp
    run Floor          = Q.floor
    run FromCelsius    = fromCelsius
    run FromFahrenheit = fromFahrenheit
    run Gamma          = Q.gamma
    run Ln             = Q.ln
    run Log10          = Q.log10
    run Round          = Q.round
    run Sin            = Q.sin
    run Sinh           = Q.sinh
    run Sqrt           = Q.sqrt >>> pure
    run Tan            = Q.tan
    run Tanh           = Q.tanh
    run ToCelsius      = toCelsius
    run ToFahrenheit   = toFahrenheit

-- | Evaluate a mathematical expression involving physical quantities.
eval ∷ Environment → Expression → Expect Quantity
eval env (Scalar n)      = pure $ Q.scalar' n
eval env (Unit u)        = pure $ Q.quantity 1.0 u
eval env (Variable name) =
  case lookup name env.values of
    Just (StoredValue _ q) → pure q
    Nothing → Left (LookupError name)
eval env (Factorial x)   = eval env x >>= Q.factorial >>> lmap QConversionError
eval env (Negate x)      = Q.qNegate <$> eval env x
eval env (Apply fn xs)   = traverse (eval env) xs >>= applyFunction fn >>= checkFinite
eval env (BinOp op x y)  = do
  x' <- eval env x
  y' <- eval env y
  (run op) x' y' >>= checkFinite
  where
    run :: BinOp -> Quantity -> Quantity -> Expect Quantity
    run Sub       a b = qSubtract a b
    run Add       a b = qAdd a b
    run Mul       a b = pure (Q.qMultiply a b)
    run Div       a b = pure (Q.qDivide a b)
    run Pow       a b = Q.pow a <$> toScalar b
    run Mod       a b = modulo a b
    run ConvertTo a b = convertTo a b

    wrap ∷ ∀ a. Either ConversionError a → Either EvalError a
    wrap = lmap QConversionError

    qSubtract q1 q2 = wrap (Q.qSubtract q1 q2)
    qAdd q1 q2 = wrap (Q.qAdd q1 q2)
    toScalar q = wrap (Q.toScalar' q)
    modulo q1 q2 = wrap (Q.modulo q1 q2)
    convertTo source target = wrap (Q.convertTo source (Q.derivedUnit target))

-- | Like `eval`, but calls `fullSimplify` on the result if the user did not
-- | ask for an explicit conversion.
evalAndSimplify ∷ Environment → Expression → Expect Quantity
evalAndSimplify env e@(BinOp ConvertTo _ _) = eval env e
evalAndSimplify env e = Q.fullSimplify <$> eval env e

-- | Render the error message for a conversion error.
conversionErrorMessage ∷ ConversionError → Markup
conversionErrorMessage (ConversionError u1 u2) =
  if u1 == Q.unity
    then
      [ F.error "  Conversion error:", F.nl, F.nl
      , F.text "    Cannot convert a ", F.unit "scalar"
      , F.text " to a quantity of unit ", F.unit (Q.toString u2)
      ]
    else
      if u2 == Q.unity
        then
          [ F.error "  Conversion error:", F.nl, F.nl
          , F.text "    Cannot convert quantity of unit "
          , F.unit (Q.toString u1)
          , F.text " to a ", F.unit "scalar"
          ]
        else
            [ F.error "  Conversion error:", F.nl, F.nl
            , F.text "    Cannot convert unit ", F.unit (Q.toString u1)
            ] <> baseRep u1 <>
            [ F.nl
            , F.text "                to unit ", F.unit (Q.toString u2)
            ] <> baseRep u2
  where
    baseRep u =
      if fst (Q.toStandardUnit u) == Q.unity
        then []
        else
          if Q.toString u == F.format F.fmtPlain usStrs
            then []
            else br
      where
        br = F.text " (base units: " : usStrs <> [ F.text ")" ]
        us = Q.baseRepresentation u
        us' = sortBy (comparing Q.toString) us
        usStrs = intercalate [ F.text "·" ] $
                   map (singleton <<< F.unit <<< Q.toString) us'


-- | Get the error message for an evaluation error.
evalErrorMessage ∷ EvalError → Markup
evalErrorMessage (QConversionError ue) =
  conversionErrorMessage ue
evalErrorMessage (LookupError name) =
  [ F.optional (F.text "  ")
  , F.error "Unknown identifier: "
  , F.ident name]
evalErrorMessage NumericalError =
  [ F.optional (F.text "  ")
  , F.error "Numerical error: "
  , F.text "division by zero or out-of-bounds error" ]
evalErrorMessage (RedefinedConstantError name) =
  [ F.optional (F.text "  ")
  , F.error "Assignment error: "
  , F.text "The constant ", F.ident name, F.text " cannot be redefined." ]

-- | Interpreter return type.
type Response = { msg ∷ Message, newEnv ∷ Environment }

-- | Show pretty-printed input and the error message.
errorWithInput ∷ Markup → Expression → Environment → EvalError → Response
errorWithInput prefix expr env err =
  { msg: Message Error $ (F.optional <$> F.text "  " : prefix <> pretty expr)
                         <> (F.optional <$> [ F.nl, F.nl ])
                         <> evalErrorMessage err
  , newEnv: env
  }

-- | Run a single statement of an Insect program.
runInsect ∷ Environment → Statement → Response
runInsect env (Expression e) =
  case evalAndSimplify env e of
    Left evalErr → errorWithInput [] e env evalErr
    Right value →
      { msg: Message Value $    (F.optional <$> F.text "  " : pretty e)
                             <> (F.optional <$> [ F.nl, F.nl , F.text "   = " ])
                             <> prettyQuantity value
      , newEnv: env { values = insert "ans" (StoredValue UserDefined value) env.values }
      }
runInsect env (Assignment n v) =
  case evalAndSimplify env v of
    Left evalErr → errorWithInput [ F.ident n, F.text " = " ] v env evalErr
    Right value →
      let response =
            { msg: Message ValueSet $
                        (F.optional <$> [ F.text "  ", F.ident n, F.text " = " ])
                     <> prettyQuantity value
            , newEnv: env { values = insert n (StoredValue UserDefined value) env.values }
          }
      in
        case lookup n env.values of
          Just (StoredValue t _) →
            if t == Constant || t == HiddenConstant
              then errorWithInput [ F.ident n, F.text " = " ] v env (RedefinedConstantError n)
              else response
          _ → response
runInsect env (Command Help) = { msg: Message Info
  [ F.emph "insect", F.text " evaluates mathematical expressions that can", F.nl
  , F.text "involve physical quantities. You can start by trying", F.nl
  , F.text "one of these examples:", F.nl
  , F.text "", F.nl
  , F.emph "  > ", F.val "1920", F.text " / ", F.val "16", F.text " * ", F.val "9", F.text "         "
  , F.emph "  > ", F.function "sin", F.text "(", F.val "30", F.text " ", F.unit "deg", F.text ")", F.nl
  , F.text "", F.nl
  , F.emph "  > ", F.val "2", F.text " ", F.unit "min", F.text " + ", F.val "30", F.text " ", F.unit "s", F.text "          "
  , F.emph "  > ", F.val "6", F.text " ", F.unit "Mbit/s", F.text " * ", F.val "1.5", F.text " ", F.unit "h", F.text " -> ", F.unit "GB", F.nl
  , F.text "", F.nl
  , F.emph "  > ", F.text "list", F.text "                  "
  , F.emph "  > ", F.ident "r", F.text " = ", F.val "80", F.text " ", F.unit "cm", F.nl
  , F.emph "  > ", F.val "40000", F.text " ", F.unit "km", F.text " / ", F.ident "c", F.text " -> ", F.unit "ms", F.text "    "
  , F.emph "  > ", F.ident "pi", F.text " * ", F.ident "r", F.text "^", F.val "2", F.text " -> ", F.unit "m", F.text "^", F.val "2", F.nl
  , F.text "", F.nl
  , F.text "Full documentation: https://github.com/sharkdp/insect"
  ], newEnv : env }
runInsect env (Command List) =
  { msg: Message Info list
  , newEnv: env }
  where
    storedValue (StoredValue _ value) = value
    storageType (StoredValue t _) = t
    visibleValues = filter (\e → storageType (snd e) /= HiddenConstant) (toUnfoldable env.values)
    envTuples = sortBy (comparing (_.number <<< Q.prettyPrint' <<< storedValue <<< snd)) visibleValues
    envGrouped = groupBy (\x y → storedValue (snd x) == storedValue (snd y)) envTuples
    envSorted = sortBy (comparing (toLower <<< fst <<< head)) envGrouped
    list = [ F.text "List of variables:", F.nl ] <> foldMap toLine envSorted
    toLine kvPairs =
         [ F.nl, F.text "  " ]
      <> identifiers
      <> [ F.text " = " ]
      <> prettyQuantity val
        where
          identifiers = fromFoldable $ intercalate [ F.text " = " ] $
                          (singleton <<< F.ident <<< fst) <$> kvPairs
          val = storedValue (snd (head kvPairs))
runInsect env (Command Reset) =
  { msg: Message Info [F.text "Environment has been reset."]
  , newEnv: initialEnvironment }
runInsect env (Command Quit) = { msg: MQuit, newEnv: initialEnvironment }
runInsect env (Command Clear) = { msg: MClear, newEnv: env }
