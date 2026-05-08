"""Technical analysis library (P2-04).

Pure deterministic functions over price/return arrays. No I/O, no LLM, no
hidden state — every call is a function of its arguments. Inputs accept
``Sequence[float]`` or ``np.ndarray``; outputs are scalar floats or small
Pydantic result containers. Insufficient data raises :class:`ValueError`.
"""

from __future__ import annotations

from collections.abc import Sequence
from math import sqrt

import numpy as np
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Result containers
# ---------------------------------------------------------------------------


class MACDResult(BaseModel):
    """MACD line, signal line, and their difference (histogram)."""

    macd: float
    signal: float
    histogram: float


class BollingerResult(BaseModel):
    """Upper / middle / lower Bollinger band values."""

    upper: float
    middle: float
    lower: float


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _to_array(
    values: Sequence[float] | np.ndarray,
    *,
    name: str = "prices",
) -> np.ndarray:
    arr = np.asarray(values, dtype=float)
    if arr.ndim != 1:
        raise ValueError(f"{name} must be 1-D, got shape {arr.shape}")
    return arr


def _require_length(arr: np.ndarray, min_length: int, *, name: str) -> None:
    if arr.size < min_length:
        raise ValueError(
            f"insufficient data for {name}: need >= {min_length}, got {arr.size}"
        )


def _ema(values: np.ndarray, period: int) -> np.ndarray:
    """EMA series, SMA-seeded.

    Length matches ``values``. Indices ``0..period-2`` are NaN since EMA is
    undefined before enough samples have accumulated.
    """
    if period <= 0:
        raise ValueError("period must be > 0")
    out = np.full_like(values, np.nan, dtype=float)
    if values.size < period:
        return out
    alpha = 2.0 / (period + 1.0)
    out[period - 1] = values[:period].mean()
    for i in range(period, values.size):
        out[i] = alpha * values[i] + (1.0 - alpha) * out[i - 1]
    return out


def _wilder_smoothed_average(values: np.ndarray, period: int) -> float:
    """Wilder's smoothing — SMA seed then ``avg = (avg * (n-1) + x) / n``.

    Returns the latest smoothed value as a Python float.
    """
    if values.size < period:
        raise ValueError("insufficient data for Wilder smoothing")
    avg = float(values[:period].mean())
    for v in values[period:]:
        avg = (avg * (period - 1) + float(v)) / period
    return avg


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def calculate_sma(
    prices: Sequence[float] | np.ndarray, period: int = 20
) -> float:
    """Latest simple moving average over ``period`` bars."""
    if period <= 0:
        raise ValueError("period must be > 0")
    arr = _to_array(prices)
    _require_length(arr, period, name="SMA")
    return float(arr[-period:].mean())


def calculate_ema(
    prices: Sequence[float] | np.ndarray, period: int = 20
) -> float:
    """Latest exponential moving average over ``period`` bars."""
    if period <= 0:
        raise ValueError("period must be > 0")
    arr = _to_array(prices)
    _require_length(arr, period, name="EMA")
    return float(_ema(arr, period)[-1])


def calculate_rsi(
    prices: Sequence[float] | np.ndarray, period: int = 14
) -> float:
    """Wilder's RSI for the latest bar.

    Conventions:
      * Flat prices (no gains, no losses) → 50.0
      * All-gain window (no losses) → 100.0
    """
    if period <= 0:
        raise ValueError("period must be > 0")
    arr = _to_array(prices)
    _require_length(arr, period + 1, name="RSI")
    diffs = np.diff(arr)
    gains = np.where(diffs > 0, diffs, 0.0)
    losses = np.where(diffs < 0, -diffs, 0.0)
    avg_gain = _wilder_smoothed_average(gains, period)
    avg_loss = _wilder_smoothed_average(losses, period)
    if avg_gain == 0.0 and avg_loss == 0.0:
        return 50.0
    if avg_loss == 0.0:
        return 100.0
    rs = avg_gain / avg_loss
    return 100.0 - (100.0 / (1.0 + rs))


def calculate_macd(
    prices: Sequence[float] | np.ndarray,
    *,
    fast: int = 12,
    slow: int = 26,
    signal: int = 9,
) -> MACDResult:
    """MACD with default 12/26/9 textbook periods."""
    if fast <= 0 or slow <= 0 or signal <= 0:
        raise ValueError("MACD periods must be > 0")
    if fast >= slow:
        raise ValueError("MACD fast period must be < slow period")
    arr = _to_array(prices)
    # Need ``slow + signal - 1`` so the signal EMA has ``signal`` valid points.
    _require_length(arr, slow + signal - 1, name="MACD")
    ema_fast = _ema(arr, fast)
    ema_slow = _ema(arr, slow)
    macd_line = ema_fast - ema_slow
    valid = macd_line[~np.isnan(macd_line)]
    signal_line = _ema(valid, signal)
    macd_value = float(macd_line[-1])
    signal_value = float(signal_line[-1])
    return MACDResult(
        macd=macd_value,
        signal=signal_value,
        histogram=macd_value - signal_value,
    )


def calculate_bollinger(
    prices: Sequence[float] | np.ndarray,
    period: int = 20,
    *,
    num_std: float = 2.0,
) -> BollingerResult:
    """Bollinger Bands using sample std (``ddof=1``) — pandas convention."""
    if period <= 0:
        raise ValueError("period must be > 0")
    if num_std <= 0:
        raise ValueError("num_std must be > 0")
    arr = _to_array(prices)
    _require_length(arr, period, name="Bollinger Bands")
    window = arr[-period:]
    middle = float(window.mean())
    std = float(window.std(ddof=1)) if period > 1 else 0.0
    return BollingerResult(
        upper=middle + num_std * std,
        middle=middle,
        lower=middle - num_std * std,
    )


def calculate_sharpe(
    returns: Sequence[float] | np.ndarray,
    risk_free_rate: float = 0.0,
    *,
    periods_per_year: int = 252,
    annualize: bool = True,
) -> float:
    """Sharpe ratio of an excess-return series.

    ``risk_free_rate`` is interpreted on the same period as ``returns``
    (e.g. daily rate for daily returns). If ``annualize=True`` (default),
    the result is scaled by ``sqrt(periods_per_year)``. Zero-volatility
    series return 0.0 instead of dividing by zero.
    """
    if periods_per_year <= 0:
        raise ValueError("periods_per_year must be > 0")
    arr = _to_array(returns, name="returns")
    _require_length(arr, 2, name="Sharpe")
    excess = arr - risk_free_rate
    std = float(excess.std(ddof=1))
    # Tolerance for "zero" volatility — guards against FP noise on series
    # whose nominal values are equal (e.g. 0.001 * N) but differ in the
    # last few bits after IEEE-754 rounding.
    if std < 1e-12:
        return 0.0
    sharpe = float(excess.mean()) / std
    if annualize:
        sharpe *= sqrt(periods_per_year)
    return sharpe
