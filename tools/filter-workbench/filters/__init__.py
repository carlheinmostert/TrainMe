"""Pluggable filter registry for the Streamlit workbench.

To add a new filter:

1. Create a new module in this folder (e.g. ``filters/my_filter.py``).
2. Define a class that subclasses :class:`filters.base.BaseFilter` with
   a populated ``params_schema`` and an ``apply`` method.
3. Import the class here and append an instance to :data:`FILTERS`.

The UI renders one dropdown entry per filter in registration order.
"""

from __future__ import annotations

from .base import BaseFilter, ParamSpec
from .pencil_sketch import PencilSketchFilter

#: Ordered registry of filter instances exposed to the UI.
FILTERS: list[BaseFilter] = [
    PencilSketchFilter(),
]


def filter_by_name(name: str) -> BaseFilter:
    """Look up a registered filter by its display name."""
    for f in FILTERS:
        if f.name == name:
            return f
    raise KeyError(f"Unknown filter: {name!r}")


__all__ = ["FILTERS", "BaseFilter", "ParamSpec", "PencilSketchFilter", "filter_by_name"]
