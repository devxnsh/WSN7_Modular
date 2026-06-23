"""Tunable constants for the CISCA-WSN reconstruction/aggregation engine."""

# --- TX -> RX matching ---
# A TX is paired with the nearest later RX of the same (type, subtype, src, dst)
# within this many ticks. Derived from WSN_Config.QUEUE_FWD_MAX/QUEUE_LOCAL_MAX (15)
# dwell time observed in [DEQUEUE] "waited %d TFs" samples, plus handshake retry
# spacing (ENC_HELLO retries, CH_REQ 16-tick blind timeout) -- widened generously
# since pairing is cheap (vectorized) and a too-narrow window just produces false
# "Not Received" classifications.
HOP_MATCH_WINDOW_TICKS = 60

# Window for linking a sensor's data arriving at a CH to that CH's subsequent
# [AGG] "Creating 5.2" batch event.
AGG_LINK_WINDOW_TICKS = 120

# System-level timeframe bucket size (ticks) for the System tab's time series.
SYSTEM_BUCKET_TICKS = 50

# Tags treated as "control/beacon" traffic -> compacted into per-node vectors
# instead of being expanded into one MessageTrace row per message.
COMPACT_TYPES = {
    "HELLO", "HB", "TOKEN",
}
# Tags (log [TAG]) that are pure scheduling/phase chatter, never carry user data,
# compacted the same way regardless of message "type".
COMPACT_TAGS = {
    "PHASE", "PHASE_TX", "PHASE_RX", "ENC_HELLO", "ENC_HELLO_TX", "ENC_HELLO_RX",
}

# Message type id -> name (mirrors WSN_Message.getTypeStr(), Utils/WSN_Message.m:529)
MSG_TYPE_NAMES = {
    0: "HELLO", 1: "SENSOR", 2: "PANIC", 5: "CH_HELLO", 6: "CH_CMD",
    7: "CMD", 8: "TOKEN", 9: "HB", 11: "CENSUS", 12: "SHUTDOWN", 13: "UPDATE",
}

# Node tiers (WSN_Node.m:37-42)
TIER_NAMES = {0: "SINK", 1: "GWN", 2: "CH", 3: "SENSOR"}

# Run-chain grouping: a terminal export (attack_log/local_features/sink_features)
# is considered part of a combined-log chain if its timestamp is within this many
# seconds after the chain's last (highest-tick) combined chunk.
RUN_TERMINAL_TOLERANCE_SECONDS = 90
