-- | Themite provides a simple model-view-action abstraction on top of `purescript-react`:
-- |
-- | - A `Spec` defines a `state` type which acts as the _model_.
-- | - The `Spec` also defines an `action` type which acts as the set of _actions_.
-- | - The `view` is a `Render` function which produces a React element for the current state.
-- | - The `PerformAction` function can be used to update the state based on an action.
-- |
-- | A `Spec` can be created using `simpleSpec`, and turned into a React component class using
-- | `createClass`.
-- |
-- | Thermite also provides type class instances and lens combinators for composing `Spec`s.

module RNX
  ( PerformAction
  , defaultPerformAction
  , EventHandler
  , Render
  , defaultRender
  , writeState
  , modifyState
  , Spec
  , _performAction
  , _render
  , simpleSpec
  , createClass
  , createReactSpec
  , withState
  , focus
  , focusState
  , match
  , split
  , foreach
  , registerComponent
  , module T
  ) where


import Prelude
import React as React
import Control.Coroutine (Transformer, CoTransformer, Transform(..), transform, transformCoTransformR, transformCoTransformL, runProcess, fuseCoTransform, cotransform)
import Control.Coroutine (CoTransformer, cotransform) as T
import Control.Monad.Aff (Aff, launchAff, makeAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff)
import Control.Monad.Free.Trans (freeT)
import Control.Monad.Rec.Class (forever)
import Control.Monad.Trans.Class (lift)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Lens (Prism', Lens', matching, view, review, preview, lens, over)
import Data.List (List(..), (!!), modifyAt)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Monoid (class Monoid)
import Data.Tuple (Tuple(..))
import RNX.Components (view')
import RNX.Styles (minHeight, height, StyleSheet, Style(..), flex, createStyleSheet, getStyleId, style)


foreign import registerComponent :: forall eff component. String -> component -> Eff eff Unit



-- | A type synonym for an action handler, which takes an action, the current props
-- | and state for the component, and return a `CoTransformer` which will emit
-- | state updates asynchronously.
-- |
-- | `Control.Coroutine.cotransform` can be used to emit state update functions
-- | and wait for the new state value. If `cotransform` returns `Nothing`, then
-- | the state could not be updated. Usually, this will not happen, but it is possible
-- | in certain use cases involving `split` and `foreach`.
type PerformAction eff state props action
   = action
  -> props
  -> state
  -> CoTransformer (Maybe state) (state -> state) (Aff eff) Unit

-- | A default `PerformAction` action implementation which ignores all actions.
defaultPerformAction :: forall eff state props action. PerformAction eff state props action
defaultPerformAction _ _ _ = pure unit

-- | Replace the current component state.
writeState :: forall state eff. state -> CoTransformer (Maybe state) (state -> state) (Aff eff) (Maybe state)
writeState st = cotransform (const st)

-- | An alias for `cotransform` - apply a function to the current component state.
modifyState :: forall state eff. (state -> state) -> CoTransformer (Maybe state) (state -> state) (Aff eff) (Maybe state)
modifyState = cotransform

-- | A type synonym for an event handler which can be used to construct
-- | `purescript-react`'s event attributes.
type EventHandler =
  forall eff refs.
    Eff ( props :: React.ReactProps
        , state :: React.ReactState React.ReadWrite
        , refs :: React.ReactRefs refs
        | eff
        ) Unit

-- | A rendering function, which takes an action handler function, the current state and
-- | props, an array of child nodes and returns a HTML document.
type Render state props action
   = (action -> EventHandler)
  -> props
  -> state
  -> Array React.ReactElement
  -> Array React.ReactElement

-- | A default `Render` implementation which renders nothing.
-- |
-- | This is useful when just `append`ing action handlers.
defaultRender :: forall state props action. Render state props action
defaultRender _ _ _ _ = []

-- | A component specification, which can be passed to `createClass`.
-- |
-- | A minimal `Spec` can be built using `simpleSpec`.
-- |
-- | The `Monoid` instance for `Spec` will compose `Spec`s by placing rendered
-- | HTML elements next to one another, and performing actions in sequence.
newtype Spec eff state props action = Spec
  { performAction      :: PerformAction eff state props action
  , render             :: Render state props action
  }

-- | A `Lens` for accessing the `PerformAction` portion of a `Spec`.
_performAction :: forall eff state props action. Lens' (Spec eff state props action) (PerformAction eff state props action)
_performAction = lens (\(Spec s) -> s.performAction) (\(Spec s) pa -> Spec (s { performAction = pa }))

-- | A `Lens` for accessing the `Render` portion of a `Spec`.
-- |
-- | This can be useful when wrapping a `Render` function in order to frame a
-- | set of controls with some containing element. For example:
-- |
-- | ```purescript
-- | wrap :: Spec _ State _ Action -> Spec _ State _ Action
-- | wrap = over _render \child dispatch props state childre  ->
-- |   [ R.div [ RP.className "wrapper" ] [ child dispatch props state children ] ]
-- | ```
_render :: forall eff state props action. Lens' (Spec eff state props action) (Render state props action)
_render = lens (\(Spec s) -> s.render) (\(Spec s) r -> Spec (s { render = r }))

-- | Create a minimal `Spec`. The arguments are, in order:
-- |
-- | - The `PerformAction` function for performing actions
-- | - The `Render` function for rendering the current state as a HTML document
-- |
-- | For example:
-- |
-- | ```purescript
-- | import qualified React.DOM as R
-- |
-- | data Action = Increment
-- |
-- | spec :: Spec _ Int _ Action
-- | spec = simpleSpec performAction render
-- |   where
-- |   render :: Render _ Int _
-- |   render _ _ n _ = [ R.text (show n) ]
-- |
-- |   performAction :: PerformAction _ Int _ Action
-- |   performAction Increment _ n k = k (n + 1)
-- | ```
simpleSpec
  :: forall eff state props action
   . PerformAction eff state props action
  -> Render state props action
  -> Spec eff state props action
simpleSpec performAction render =
  Spec { performAction: performAction
       , render: render
       }

instance semigroupSpec :: Semigroup (Spec eff state props action) where
  append (Spec spec1) (Spec spec2) =
    Spec { performAction:       \a p s -> do spec1.performAction a p s
                                             spec2.performAction a p s
         , render:              \k p s   -> spec1.render k p s <> spec2.render k p s
         }

instance monoidSpec :: Monoid (Spec eff state props action) where
  mempty = simpleSpec (\_ _ _ -> pure unit)
                      (\_ _ _ _ -> [])

-- | Create a React component class from a Thermite component `Spec`.
createClass
  :: forall eff state props action
   . Spec eff state props action
  -> state
  -> React.ReactClass props
createClass spec state = React.createClass <<< _.spec $ createReactSpec spec state

-- | Create a React component spec from a Thermite component `Spec`.
-- |
-- | This function is a low-level alternative to `createClass`, used when the React
-- | component spec needs to be modified before being turned into a component class,
-- | e.g. by adding additional lifecycle methods.
createReactSpec
  :: forall eff state props action
   . Spec eff state props action
  -> state
  -> { spec :: React.ReactSpec props state eff
     , dispatcher :: React.ReactThis props state -> action -> EventHandler
     }
createReactSpec (Spec spec) state =
    { spec: React.spec state render
    , dispatcher
    }
  where
    dispatcher :: React.ReactThis props state -> action -> EventHandler
    dispatcher this action = void do
      props <- React.getProps this
      state <- React.readState this
      let coerceEff :: forall eff1 a. Eff eff1 a -> Eff eff a
          coerceEff = unsafeCoerceEff

          put :: state -> Aff eff state
          put new = makeAff \_ k -> unsafeCoerceEff do
            void $ React.writeStateWithCallback this new (unsafeCoerceEff (k new))

          transformer :: Transformer (state -> state) (Maybe state) (Aff eff) Unit
          transformer = forever $ freeT \_ -> do
            old <- liftEff (coerceEff (React.readState this))
            pure (Right (Transform \f ->
              let new = f old
              in Tuple (Just new) (lift (put new))))

      let process = transformer `fuseCoTransform` spec.performAction action props state

      unsafeCoerceEff (launchAff (runProcess process))

    render :: React.Render props state eff
    render this = map (view' [style $ getStyleId styleSheet "wrapper"]) $
      spec.render (dispatcher this)
        <$> React.getProps this
        <*> React.readState this
        <*> React.getChildren this

-- | This function captures the state of the `Spec` as a function argument.
-- |
-- | This can sometimes be useful in complex scenarios involving the `focus` and
-- | `foreach` combinators.
withState
  :: forall eff state props action
   . (state -> Spec eff state props action)
  -> Spec eff state props action
withState f = simpleSpec performAction render
  where
    performAction :: PerformAction eff state props action
    performAction a p st = view _performAction (f st) a p st

    render :: Render state props action
    render k p st = view _render (f st) k p st

-- | Change the state type, using a lens to focus on a part of the state.
-- |
-- | For example, to combine two `Spec`s, combining state types using `Tuple`
-- | and action types using `Either`:
-- |
-- | ```purescript
-- | spec1 :: Spec _ S1 _ A1
-- | spec2 :: Spec _ S2 _ A2
-- |
-- | spec :: Spec _ (Tuple S1 S2) _ (Either A1 A2)
-- | spec = focus _1 _Left spec1 <> focus _2 _Right spec2
-- | ```
-- |
-- | Actions will only be handled when the prism matches its input, otherwise
-- | the action will be ignored, and should be handled by some other component.
focus
  :: forall eff props state2 state1 action1 action2
   . Lens' state2 state1
  -> Prism' action2 action1
  -> Spec eff state1 props action1
  -> Spec eff state2 props action2
focus lens prism (Spec spec) = Spec { performAction, render }
  where
    performAction :: PerformAction eff state2 props action2
    performAction a p st =
      case matching prism a of
        Left _ -> pure unit
        Right a' -> forever (transform (map (view lens)))
                    `transformCoTransformL` spec.performAction a' p (view lens st)
                    `transformCoTransformR` forever (transform (over lens))

    render :: Render state2 props action2
    render k p st = spec.render (k <<< review prism) p (view lens st)

-- | A variant of `focus` which only changes the state type, by applying a `Lens`.
focusState
  :: forall eff props state2 state1 action
   . Lens' state2 state1
  -> Spec eff state1 props action
  -> Spec eff state2 props action
focusState lens = focus lens id

-- | A variant of `focus` which only changes the action type, by applying a `Prism`,
-- | effectively matching some subset of a larger action type.
match
  :: forall eff props state action1 action2
   . Prism' action2 action1
  -> Spec eff state props action1
  -> Spec eff state props action2
match prism = focus id prism

-- | Create a component which renders an optional subcomponent.
split
  :: forall eff props state1 state2 action
   . Prism' state1 state2
  -> Spec eff state2 props action
  -> Spec eff state1 props action
split prism (Spec spec) = Spec { performAction, render }
  where
    performAction :: PerformAction eff state1 props action
    performAction a p st =
      case matching prism st of
        Left _ -> pure unit
        Right st2 -> forever (transform (_ >>= preview prism))
                     `transformCoTransformL` spec.performAction a p st2
                     `transformCoTransformR` forever (transform (over prism))

    render :: Render state1 props action
    render k p st children =
      case matching prism st of
        Left _ -> []
        Right st' -> spec.render k p st' children

-- | Create a component whose state is described by a list, displaying one subcomponent
-- | for each entry in the list.
-- |
-- | The action type is modified to take the index of the originating subcomponent as an
-- | additional argument.
foreach
  :: forall eff props state action
   . (Int -> Spec eff state props action)
  -> Spec eff (List state) props (Tuple Int action)
foreach f = Spec
    { performAction: performAction
    , render: render
    }
  where
    performAction :: PerformAction eff (List state) props (Tuple Int action)
    performAction (Tuple i a) p sts =
        for_ (sts !! i) \st ->
          case f i of
            Spec s -> forever (transform (_ >>= (_ !! i)))
                      `transformCoTransformL` s.performAction a p st
                      `transformCoTransformR` forever (transform (modifying i))
      where
        modifying :: Int -> (state -> state) -> List state -> List state
        modifying i f sts' = fromMaybe sts' (modifyAt i f sts')

    render :: Render (List state) props (Tuple Int action)
    render k p sts _ = foldWithIndex (\i st els -> case f i of Spec s -> els <> s.render (k <<< Tuple i) p st []) sts []

    foldWithIndex :: forall a r. (Int -> a -> r -> r) -> List a -> r -> r
    foldWithIndex f = go 0
      where
      go _ Nil         r = r
      go i (Cons x xs) r = go (i + 1) xs (f i x r)


styleSheet :: StyleSheet
styleSheet =
  createStyleSheet
  [ Style "wrapper"
    [ flex 1
    ]
  ]
