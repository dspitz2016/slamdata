{-
Copyright 2016 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module SlamData.Workspace.Eval.Persistence where

import SlamData.Prelude

import Control.Monad.Aff (later')
import Control.Monad.Aff.AVar (AVar, makeVar, takeVar, putVar, modifyVar, killVar)
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Free (class Affable, fromAff)
import Control.Monad.Aff.Promise (wait, defer)
import Control.Monad.Eff.Exception as Exn
import Control.Monad.Fork (class MonadFork, fork)

import Data.Array as Array
import Data.List (List(..), (:))
import Data.List as List
import Data.Map as Map

import SlamData.Effects (SlamDataEffects)
import SlamData.Quasar.Data as Quasar
import SlamData.Quasar.Class (class QuasarDSL)
import SlamData.Quasar.Error as QE
import SlamData.Workspace.AccessType (isEditable)
import SlamData.Workspace.Card.CardId as CID
import SlamData.Workspace.Card.Port (Port)
import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.Deck.DeckId as DID
import SlamData.Workspace.Eval as Eval
import SlamData.Workspace.Eval.Card as Card
import SlamData.Workspace.Eval.Deck as Deck
import SlamData.Workspace.Eval.Graph (unfoldGraph, EvalGraph)
import SlamData.Wiring (Wiring)
import SlamData.Wiring as Wiring
import SlamData.Wiring.Cache as Cache

import Utils (censor)

defaultSaveDebounce ∷ Int
defaultSaveDebounce = 500

defaultEvalDebounce ∷ Int
defaultEvalDebounce = 500

type Persist f m a =
  ( Affable SlamDataEffects m
  , MonadAsk Wiring m
  , MonadFork Exn.Error m
  , Parallel f m
  , QuasarDSL m
  ) ⇒ a

putDeck ∷ ∀ f m. Persist f m (Deck.Id → Deck.Model → m (Either QE.QError Unit))
putDeck deckId deck = do
  { path, eval, accessType } ← Wiring.expose
  ref ← defer do
    res ←
      if isEditable accessType
        then Quasar.save (Deck.deckIndex path deckId) $ Deck.encode deck
        else pure (Right unit)
    pure $ res $> deck
  Cache.alter deckId
    (\cell → pure $ _ { value = ref } <$> cell)
    eval.decks
  rmap (const unit) <$> wait ref

saveDeck ∷ ∀ f m. Persist f m (Deck.Id → m Unit)
saveDeck deckId = do
  { eval } ← Wiring.expose
  newDeck ← runMaybeT do
    cell ← MaybeT $ Cache.get deckId eval.decks
    deck ← MaybeT $ censor <$> wait cell.value
    cards ← MaybeT $ sequence <$> traverse getCard (Tuple deckId ∘ _.cardId <$> deck.cards)
    pure deck { cards = (\c → c.value.model) <$> cards }
  for_ newDeck (void ∘ putDeck deckId)

-- | Loads a deck from a DeckId. Returns the model.
getDeck ∷ ∀ f m. Persist f m (Deck.Id → m (Either QE.QError Deck.Model))
getDeck =
  getDeck' >=> _.value >>> wait

-- | Loads a deck from a DeckId. This has the effect of loading decks from
-- | which it extends (for mirroring) and populating the card graph. Returns
-- | the "cell" (model promise paired with its message bus).
getDeck' ∷ ∀ f m. Persist f m (Deck.Id → m Deck.Cell)
getDeck' deckId = do
  { path, eval } ← Wiring.expose
  let
    cacheVar = Cache.unCache eval.decks
  decks ← fromAff (takeVar cacheVar)
  case Map.lookup deckId decks of
    Just cell → do
      fromAff $ putVar cacheVar decks
      pure cell
    Nothing → do
      value ← defer do
        let
          deckPath = Deck.deckIndex path deckId
        -- FIXME: Notify on failure
        result ← runExceptT do
          deck ← ExceptT $ (_ >>= Deck.decode >>> lmap QE.msgToQError) <$> Quasar.load deckPath
          _    ← ExceptT $ populateCards deckId deck
          pure deck
        case result of
          Left _ →
            fromAff $ modifyVar (Map.delete deckId) cacheVar
          Right model →
            Cache.alter deckId (pure ∘ map (_ { model = model })) eval.decks
        pure result
      cell ← { value, model: Deck.emptyDeck, bus: _ } <$> fromAff Bus.make
      fromAff do
        putVar cacheVar (Map.insert deckId cell decks)
      forkDeckProcess deckId cell.bus
      pure cell

-- | Populates the card eval graph based on a deck model. This may fail as it
-- | also attempts to load/hydrate foreign cards (mirrors) as well.
populateCards ∷ ∀ f m. Persist f m (Deck.Id → Deck.Model → m (Either QE.QError Unit))
populateCards deckId deck = runExceptT do
  { eval } ← Wiring.expose
  decks ←
    ExceptT $ sequence <$>
      parTraverse getDeck (Array.nub (fst <$> deck.mirror))

  case Array.last deck.mirror, List.fromFoldable deck.cards of
    Just _    , Nil    → pure unit
    Nothing   , cards  → lift $ threadCards eval.cards cards
    Just coord, c : cs → do
      cell ← do
        mb ← Cache.get coord eval.cards
        case mb of
          Nothing → QE.throw ("Card not found in eval cache: " <> show coord)
          Just a  → pure a
      let
        coord' = deckId × c.cardId
        cell' = cell { next = coord' : cell.next }
      Cache.put coord cell' eval.cards
      lift $ threadCards eval.cards (c : cs)

  where
    threadCards cache = case _ of
      Nil         → pure unit
      c : Nil     → makeCell c Nil cache
      c : c' : cs → do
        makeCell c (pure c'.cardId) cache
        threadCards cache (c' : cs)

    makeCell card next cache = do
      let
        coord = deckId × card.cardId
      cell ← makeCardCell card Nothing (Tuple deckId <$> next)
      Cache.put coord cell cache
      forkCardProcess coord cell.bus

makeCardCell
  ∷ ∀ m
  . ( Affable SlamDataEffects m
    , Monad m
    )
  ⇒ Card.Model
  → Maybe Port
  → List Card.Coord
  → m Card.Cell
makeCardCell model input next = do
  let
    value =
      { model
      , input
      , output: Nothing
      , state: Nothing
      , tick: Nothing
      }
  bus ← fromAff Bus.make
  pure { bus, next, value }

getCard
  ∷ ∀ m
  . ( Affable SlamDataEffects m
    , MonadAsk Wiring m
    )
  ⇒ Card.Coord
  → m (Maybe Card.Cell)
getCard coord = do
  { eval } ← Wiring.expose
  Cache.get coord eval.cards

forkLoop
  ∷ ∀ m r a
  . ( Affable SlamDataEffects m
    , MonadFork Exn.Error m
    )
  ⇒ (a → m Unit)
  → Bus.Bus (Bus.R' r) a
  → m Unit
forkLoop handler bus = void (fork loop)
  where
    loop = do
      msg ← fromAff (Bus.read bus)
      fork (handler msg)
      loop

forkDeckProcess ∷ ∀ f m . Persist f m (Deck.Id → Bus.BusRW Deck.EvalMessage → m Unit)
forkDeckProcess deckId = forkLoop case _ of
  Deck.Force source →
    queueEval' 0 source
  Deck.AddCard cty → do
    { eval } ← Wiring.expose
    deckCell ← getDeck' deckId
    mbDeck ← wait deckCell.value
    for_ mbDeck \deck → do
      cardId ← fromAff CID.make
      let
        coord = deckId × cardId
      input ← runMaybeT do
        last ← MaybeT $ pure $ Array.last (Deck.cardCoords deckId deck)
        cell ← MaybeT $ Cache.get last eval.cards
        lift $ Cache.put last (cell { next = coord : cell.next }) eval.cards
        MaybeT $ pure $ cell.value.output
      let
        card = { cardId, model: Card.cardModelOfType (fromMaybe Port.Initial input) cty }
        deck' = deck { cards = Array.snoc deck.cards card }
      cell ← makeCardCell card input mempty
      value' ← defer (pure (Right deck'))
      Cache.put (deckId × cardId) cell eval.cards
      Cache.put deckId (deckCell { value = value' }) eval.decks
      forkCardProcess coord cell.bus
      queueSave defaultSaveDebounce deckId
      queueEval' 0 (mempty × coord)
  Deck.RemoveCard coord@(deckId' × cardId) → do
    { eval } ← Wiring.expose
    deckCell ← getDeck' deckId
    mbDeck ← wait deckCell.value
    for_ mbDeck \deck → do
      let
        coords = Array.span (not ∘ eq coord) (Deck.cardCoords deckId deck)
        deck' =
          if deckId ≡ deckId'
            then deck { cards = Array.takeWhile (not ∘ eq cardId ∘ _.cardId) deck.cards }
            else deck { cards = [], mirror = Array.takeWhile (not ∘ eq coord) deck.mirror }
      output ← runMaybeT do
        last ← MaybeT $ pure $ Array.last coords.init
        cell ← MaybeT $ Cache.get last eval.cards
        lift $ Cache.put last (cell { next = List.delete coord cell.next }) eval.cards
        MaybeT $ pure $ cell.value.output
      value' ← defer (pure (Right deck'))
      Cache.put deckId (deckCell { value = value' }) eval.decks
      queueSave defaultSaveDebounce deckId
      fromAff $ Bus.write (Deck.Complete coords.init (fromMaybe Port.Initial output)) deckCell.bus
  _ →
    pure unit

forkCardProcess ∷ ∀ f m. Persist f m (Card.Coord → Bus.BusRW Card.EvalMessage → m Unit)
forkCardProcess coord@(deckId × cardId) = forkLoop case _ of
  Card.ModelChange source model → do
    { eval } ← Wiring.expose
    Cache.alter coord (pure ∘ map (updateModel model)) eval.cards
    mbGraph ← snapshotGraph coord
    for_ mbGraph \graph → do
      queueSave defaultSaveDebounce deckId
      queueEval defaultEvalDebounce source graph
  _ →
    pure unit

  where
    -- TODO: Lenses?
    updateModel model cell = cell
      { value = cell.value
          { model = cell.value.model
              { model = model
              }
          }
      }

snapshotGraph ∷ ∀ f m. Persist f m (Card.Coord → m (Maybe EvalGraph))
snapshotGraph coord = do
  { eval } ← Wiring.expose
  unfoldGraph
    <$> Cache.snapshot eval.cards
    <*> Cache.snapshot eval.decks
    <*> pure coord

queueSave ∷ ∀ f m. Persist f m (Int → Deck.Id → m Unit)
queueSave ms deckId = do
  { eval } ← Wiring.expose
  debounce ms deckId { avar: _ } eval.pendingSaves do
    saveDeck deckId

queueEval ∷ ∀ f m. Persist f m (Int → Card.DisplayCoord → EvalGraph → m Unit)
queueEval ms source@(_ × coord) graph = do
  { eval } ← Wiring.expose
  let
    pending =
      { source
      , graph
      , avar: _
      }
  -- TODO: Notify pending immediately
  debounce ms coord pending eval.pendingEvals do
    Eval.evalGraph source graph

queueEval' ∷ ∀ f m. Persist f m (Int → Card.DisplayCoord → m Unit)
queueEval' ms source@(_ × coord) =
  traverse_ (queueEval ms source) =<< snapshotGraph coord

freshWorkspace ∷ ∀ f m. Persist f m (m (Deck.Id × Deck.Cell))
freshWorkspace = do
  { eval } ← Wiring.expose
  rootId ← fromAff DID.make
  bus ← fromAff Bus.make
  value ← defer (pure (Right Deck.emptyDeck))
  let
    cell = { bus, value, model: Deck.emptyDeck }
  Cache.put rootId cell eval.decks
  forkDeckProcess rootId bus
  pure (rootId × cell)

debounce
  ∷ ∀ k m r
  . ( Affable SlamDataEffects m
    , MonadAsk Wiring m
    , MonadFork Exn.Error m
    , Ord k
    )
  ⇒ Int
  → k
  → (AVar Unit → { avar ∷ AVar Unit | r })
  → Cache.Cache k { avar ∷ AVar Unit | r }
  → m Unit
  → m Unit
debounce ms key make cache run = do
  avar ← laterVar ms $ void $ run *> Cache.remove key cache
  Cache.alter key (alterFn (make avar)) cache
  where
    alterFn a b = fromAff do
      traverse_ (flip killVar (Exn.error "debounce") ∘ _.avar) b
        $> Just a

laterVar
  ∷ ∀ m
  . ( Affable SlamDataEffects m
    , MonadAsk Wiring m
    , MonadFork Exn.Error m
    )
  ⇒ Int
  → m Unit
  → m (AVar Unit)
laterVar ms run = do
  avar ← fromAff makeVar
  fork $ fromAff (takeVar avar) *> run
  fork $ fromAff $ later' ms (putVar avar unit)
  pure avar
