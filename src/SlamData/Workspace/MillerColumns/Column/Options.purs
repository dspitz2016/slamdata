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

module SlamData.Workspace.MillerColumns.Column.Options where

import SlamData.Prelude

import Data.List as L

import Halogen as H
import Halogen.HTML as HH

import SlamData.Monad (Slam)
import SlamData.Workspace.MillerColumns.Column.Component.Item (ItemMessage', ItemQuery', ItemState)

type LoadParams i = { path ∷ L.List i, filter ∷ String, offset ∷ Maybe Int }

type ColumnOptions a i f m =
  { render
      ∷ L.List i
      → a
      → H.Component HH.HTML (ItemQuery' f) ItemState (ItemMessage' a m) Slam
  , label ∷ a → String
  , load ∷ LoadParams i → Slam { items ∷ L.List a, nextOffset ∷ Maybe Int }
  , isLeaf ∷ L.List i → Boolean
  , id ∷ a → i
  }
