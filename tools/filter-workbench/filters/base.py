"""Base classes for pluggable filters used by the Streamlit workbench.

A filter is a small class with:

- a ``name`` (shown in the dropdown),
- an optional ``description`` (a one-liner shown above the sliders),
- a ``params_schema`` dict mapping parameter names to :class:`ParamSpec`
  values (the UI auto-renders one widget per entry),
- an ``apply(gray_frame, params)`` method that takes a single-channel
  uint8 grayscale frame and returns another single-channel uint8
  grayscale frame.

Segmentation and two-zone compositing happen **outside** of this method
— filters only produce the filter output. The Streamlit app layers
MediaPipe person segmentation on top to match the on-device behaviour.

Adding a new filter is a three-step operation:

1. Drop a new ``.py`` file in this folder with a class that subclasses
   :class:`BaseFilter`.
2. Describe its parameters using :class:`ParamSpec` entries in
   ``params_schema``.
3. Append an instance to the ``FILTERS`` list in ``filters/__init__.py``.

See :mod:`filters.pencil_sketch` for a reference implementation.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import numpy as np


@dataclass(frozen=True)
class ParamSpec:
    """Specification for a single filter parameter.

    The Streamlit UI uses these fields to pick the right widget:

    - ``kind == "int"``  -> ``st.slider`` with integer step
    - ``kind == "float"`` -> ``st.slider`` with float step
    - ``kind == "bool"`` -> ``st.checkbox`` (``min``/``max``/``step`` ignored)

    ``odd_only`` is a hint for integer sliders where only odd values are
    valid (e.g. convolution kernel sizes). The UI enforces this by
    snapping values up to the next odd integer.
    """

    min: float
    max: float
    default: float | bool
    step: float = 1.0
    description: str = ""
    kind: str = "int"  # one of: "int", "float", "bool"
    odd_only: bool = False


class BaseFilter(ABC):
    """Abstract base class for a workbench filter.

    Concrete filters only implement :meth:`apply`. The Streamlit app is
    responsible for:

    - converting the source RGB frame to grayscale before calling
      ``apply``,
    - feeding in parameter values whose names match
      ``params_schema`` keys,
    - running MediaPipe segmentation + two-zone compositing on the
      returned grayscale buffer.
    """

    #: Short display name shown in the dropdown.
    name: str = ""

    #: Optional longer blurb shown in the sidebar.
    description: str = ""

    #: Mapping of parameter name -> :class:`ParamSpec`. The UI renders
    #: one widget per entry, in insertion order.
    params_schema: dict[str, ParamSpec] = {}

    @abstractmethod
    def apply(self, gray_frame: np.ndarray, params: dict[str, Any]) -> np.ndarray:
        """Run the filter on a single-channel uint8 grayscale frame.

        :param gray_frame: ``(H, W)`` uint8 grayscale input.
        :param params: dict of parameter values keyed by the names in
            ``params_schema``. Values are already coerced to the correct
            Python types by the UI.
        :returns: ``(H, W)`` uint8 grayscale output.
        """
        raise NotImplementedError

    def default_params(self) -> dict[str, Any]:
        """Return a params dict populated with schema defaults."""
        return {name: spec.default for name, spec in self.params_schema.items()}
