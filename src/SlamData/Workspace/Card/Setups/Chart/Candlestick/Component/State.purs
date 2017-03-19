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

module SlamData.Workspace.Card.Setups.Chart.Candlestick.Component.State
  ( allFields
  , cursors
  , disabled
  , load
  , save
  , initialState
  , State
  , module C
  ) where

import SlamData.Prelude

import Data.Argonaut as J
import Data.Lens (Traversal', Lens', _Just, (^.), (.~), (^?))
import Data.Lens.At (at)
import Data.List as List
import Data.Set as Set
import Data.StrMap as SM

import SlamData.Workspace.Card.Model as M
import SlamData.Workspace.Card.Setups.Axis as Ax
import SlamData.Workspace.Card.Setups.Common.State as C
import SlamData.Workspace.Card.Setups.Dimension as D

type State = C.StateR ()

allFields ∷ Array C.Projection
allFields =
  [ C.pack (at "dimension" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  , C.pack (at "open" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  , C.pack (at "close" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  , C.pack (at "high" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  , C.pack (at "low" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  , C.pack (at "parallel" ∷ ∀ a. Lens' (SM.StrMap a) (Maybe a))
  ]

cursors ∷ State → List.List J.JCursor
cursors st = case st.selected of
  Just (Left lns) → List.fromFoldable $ fldCursors lns st
  _ → List.Nil

disabled ∷ C.Projection → State → Boolean
disabled fld st = Set.isEmpty $ fldCursors fld st

fldCursors ∷ C.Projection → State → Set.Set J.JCursor
fldCursors fld st =
  fromMaybe Set.empty $ cursorMap st ^. C.unpack fld

cursorMap ∷ State → SM.StrMap (Set.Set J.JCursor)
cursorMap st =
  let
    mbDelete ∷ ∀ a. Ord a ⇒ Maybe a → Set.Set a → Set.Set a
    mbDelete mbA s = maybe s (flip Set.delete s) mbA

    _projection ∷ Traversal' (Maybe D.LabeledJCursor) J.JCursor
    _projection = _Just ∘ D._value ∘ D._projection

    axes = st ^. C._axes

    open =
      axes.value
    close =
      mbDelete (st ^? C._open ∘ _projection)
      $ axes.value
    high =
      mbDelete (st ^? C._open ∘ _projection)
      $ mbDelete (st ^? C._close ∘ _projection)
      $ axes.value
    low =
      mbDelete (st ^? C._open ∘ _projection)
      $ mbDelete (st ^? C._close ∘ _projection)
      $ mbDelete (st ^? C._high ∘ _projection)
      $ axes.value
    dimension =
      axes.category
      ⊕ axes.time
      ⊕ axes.date
      ⊕ axes.datetime
    parallel =
      mbDelete (st ^? C._dimension ∘ _projection)
      $ axes.category

  in
   SM.fromFoldable
     [ "open" × open
     , "close" × close
     , "high" × high
     , "low" × low
     , "dimension" × dimension
     , "parallel" × parallel
     ]

initialState ∷ State
initialState =
  { axes: Ax.initialAxes
  , dimMap: SM.empty
  , selected: Nothing
  }

load ∷ M.AnyCardModel → State → State
load = case _ of
  M.BuildCandlestick (Just m) →
    ( C._dimension .~ Just m.dimension )
    ∘ ( C._open .~ Just m.open )
    ∘ ( C._close .~ Just m.close )
    ∘ ( C._low .~ Just m.low )
    ∘ ( C._high .~ Just m.high )
    ∘ ( C._parallel .~ m.parallel )
  _ → id

save ∷ State → M.AnyCardModel
save st =
  M.BuildCandlestick
  $ { dimension: _
    , open: _
    , close: _
    , high: _
    , low: _
    , parallel: st ^. C._parallel
    }
  <$> (st ^. C._dimension)
  <*> (st ^. C._open)
  <*> (st ^. C._close)
  <*> (st ^. C._high)
  <*> (st ^. C._low)
