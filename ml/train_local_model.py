"""ML_IDS_PLAN.md Phase 5: train the local (node-tier) IDS model.

Consumes logs/local_dataset.csv -- the Local Telemetry dataset, tapped at
the source with full node self-visibility -- restricted to the paper's
6-feature local-tier subset (RSSI, PDR, RetransmitCount, ResidualEnergy,
PhaseHoldTime, QueueDepth).

BINARY, not multi-class (changed 2026-06-19, verified against the paper
"A Secure Architecture for ML-Enforced Attack Mitigation in WSNs"):
the paper's local tier never classifies attack TYPE -- it only needs a
suspicion signal cheap enough to run on constrained hardware. Quoting the
paper directly: "confidently identifying a malicious neighbor is
difficult for a single sensor node that lacks a global source of truth
for feedback... The actual identification of a malicious node is handled
through daisy-chained polling amongst immediate neighbors" -- i.e. WHICH
attack and WHETHER a node is truly malicious is decided by the rule-based
Census protocol (WSN_Gateway/Sensor/ClusterHead.checkCensusTriggers,
ML_IDS_PLAN.md Phase 4), not by this model. This script's job is only to
produce that trigger signal: Attack vs Normal.

Models are deliberately light (the paper: Sink compute "is not the
bottleneck"; edge deployment "is reserved for a pruned DTC variant") --
DecisionTree is the recommended deployment choice (cheapest: a handful of
if/else comparisons, trivially portable to a microcontroller), with a
small RandomForest and a LogisticRegression trained alongside purely as
reference points.

Trial-and-error finding (see AI_ENGINE_DEBUG_PROMPT.md for full detail):
precision on the Attack class is unavoidably low (~1-3%) at this feature
set and class ratio (176:1) -- but recall is ~70-85%, which is what
actually matters for a trigger role: most real attacks DO get flagged for
Census corroboration, and the polling/quorum step (not this model) is
what filters out false positives before any enforcement action. Treating
this as a precision problem to "fix" would be solving the wrong metric
for the architecture's actual division of labor.

Depth was retuned from 4 to 8 in a follow-up trial: depth=8 beats depth=4
on accuracy, recall, AND precision simultaneously (a single tree, still
the lightest possible model -- depth=8 is at most 256 leaves, nowhere
near an ensemble's footprint). Depth=3 was tried and rejected despite its
98%+ recall: it flags two-thirds of all Normal traffic too, which would
keep the Census layer in constant false-alarm mode. An unbounded-depth
tree was also tried and rejected for the opposite reason: it nearly
memorizes the training set (99.2% accuracy, 27.6% precision) but recall
collapses to 24.6% -- useless as a trigger that's supposed to catch most
real attacks. LightGBM/XGBoost were also tried at comparable per-tree
depth with a handful of trees (5-20) and did not beat a single depth-8
tree on this dataset -- not worth the added ensemble footprint here.

Usage:
    python train_local_model.py --csv ../logs/local_dataset.csv
"""
import argparse
import os

from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.tree import DecisionTreeClassifier

from wsn_ids_common import (
    class_distribution,
    ensure_dir,
    evaluate_model,
    load_dataset,
    resample_training_data,
    save_accuracy_comparison,
    save_confusion_matrix,
    save_feature_importance,
    save_json_report,
    save_per_class_f1,
    save_precision_recall,
)

LOCAL_TIER_FEATURES = ["RSSI", "PDR", "RetransmitCount", "ResidualEnergy", "PhaseHoldTime", "QueueDepth"]
ATTACK_TYPE_COL = "AttackTypeName"  # kept only for the breakdown CSV, not the label
LABEL_COL = "BinaryLabel"


def build_features(df):
    missing = [c for c in LOCAL_TIER_FEATURES if c not in df.columns]
    if missing:
        raise ValueError(f"local_dataset.csv is missing expected columns: {missing}")
    X = df[LOCAL_TIER_FEATURES].copy()

    # KNOWN DATA GAP: PhaseHoldTime is NaN for 100% of Sensor/CH-tier rows in
    # the current dataset (only populated for GWN-tier rows) -- a
    # WSN_FeatureExport.m tap-site bug, not an ML issue. Per user decision the
    # dataset isn't being regenerated right now, so impute with an explicit
    # sentinel (distinguishable from any real value) rather than silently
    # dropping the column, since it's one of the paper's defined 6 local-tier
    # features and SMOTE/sklearn can't train on raw NaN anyway.
    if X["PhaseHoldTime"].isna().any():
        print(f"  [WARN] PhaseHoldTime is NaN for {X['PhaseHoldTime'].isna().mean():.1%} of rows "
              f"(known WSN_FeatureExport.m tap-site gap, see AI_ENGINE_DEBUG_PROMPT.md) -- imputing with -1 sentinel")
        X["PhaseHoldTime"] = X["PhaseHoldTime"].fillna(-1)

    y = df["IsMalicious"].map({0: "Normal", 1: "Attack"})
    return X, y, LOCAL_TIER_FEATURES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default="../logs/local_dataset.csv")
    parser.add_argument("--output-dir", default="results/local")
    parser.add_argument("--test-size", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--max-depth", type=int, default=8,
                         help="Cap for DecisionTree/RandomForest. Trial-and-error found depth=8 the best "
                              "accuracy/recall/precision balance for a single tree: depth=3 over-flags almost "
                              "everything as Attack (98%% recall but ~67%% Normal-traffic false-alarm rate); "
                              "unbounded depth nearly memorizes training data (99%% accuracy but 25%% recall, "
                              "useless as a trigger).")
    parser.add_argument("--n-estimators", type=int, default=10, help="RF tree count (kept small for the local tier)")
    parser.add_argument("--resample", action="store_true",
                         help="Undersample Normal / SMOTE Attack before training. Tested for the binary task and "
                              "found to make no meaningful difference (recall within 1-2 points either way) -- off "
                              "by default.")
    parser.add_argument("--resample-target", type=int, default=2000,
                         help="Per-class row count target if --resample is set (capped at 10x each class's real count)")
    args = parser.parse_args()

    ensure_dir(args.output_dir)

    df = load_dataset(args.csv)
    print(f"Loaded {len(df)} rows from {args.csv}")

    # Binary distribution (what the model actually trains on)
    df["BinaryLabel"] = df["IsMalicious"].map({0: "Normal", 1: "Attack"})
    dist = class_distribution(df, LABEL_COL)
    dist.to_csv(os.path.join(args.output_dir, "class_distribution.csv"), index=False)
    print(dist.to_string(index=False))

    # Reference only: what real attack types are lumped into "Attack"
    breakdown = class_distribution(df, ATTACK_TYPE_COL)
    breakdown.to_csv(os.path.join(args.output_dir, "attack_type_breakdown.csv"), index=False)

    X, y, feature_cols = build_features(df)
    class_names = ["Normal", "Attack"]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=args.test_size, random_state=args.seed, stratify=y
    )
    print(f"Train: {len(X_train)} rows, Test: {len(X_test)} rows, Features: {feature_cols}")

    if args.resample:
        X_train, y_train = resample_training_data(X_train, y_train, args.resample_target, args.seed)
        print(f"After resampling (target={args.resample_target}/class): Train: {len(X_train)} rows")
        print(y_train.value_counts().to_string())

    models = {
        # Recommended deployment choice: a single pruned tree, matching the
        # paper's explicit guidance for edge/constrained hardware.
        "DecisionTree": DecisionTreeClassifier(
            max_depth=args.max_depth, class_weight="balanced", random_state=args.seed
        ),
        "RandomForest": RandomForestClassifier(
            n_estimators=args.n_estimators,
            max_depth=args.max_depth,
            class_weight="balanced",
            random_state=args.seed,
            n_jobs=-1,
        ),
        # Reference only: cheapest possible model (a single dot product +
        # threshold), included for comparison since "lightest model" was an
        # explicit goal -- trial-and-error found it strictly worse recall
        # than the tree options, so it's not the recommended choice.
        "LogisticRegression": make_pipeline(
            StandardScaler(), LogisticRegression(class_weight="balanced", random_state=args.seed, max_iter=1000)
        ),
    }

    results = {}
    for name, model in models.items():
        depth_note = f" (shallow: max_depth={args.max_depth})" if "LogisticRegression" not in name else ""
        print(f"\nTraining {name}{depth_note}...")
        model.fit(X_train, y_train)
        res = evaluate_model(model, X_test, y_test, class_names)
        results[name] = res
        attack_stats = res["report"]["Attack"]
        print(f"  Accuracy: {res['accuracy']:.4f}  Attack recall: {attack_stats['recall']:.4f}  "
              f"Attack precision: {attack_stats['precision']:.4f}")

        prefix = os.path.join(args.output_dir, f"confusion_matrix_{name}")
        save_confusion_matrix(res["confusion_matrix"], class_names, prefix)

        # LogisticRegression is a Pipeline -- feature_importances_ lives on
        # neither the pipeline nor cleanly maps to raw features, skip it.
        if hasattr(model, "feature_importances_"):
            save_feature_importance(
                model, feature_cols, os.path.join(args.output_dir, f"feature_importance_{name}")
            )

    save_accuracy_comparison(results, os.path.join(args.output_dir, "accuracy_comparison.csv"))
    save_per_class_f1(results, os.path.join(args.output_dir, "per_class_f1.csv"))
    save_precision_recall(results, class_names, os.path.join(args.output_dir, "precision_recall.csv"))
    save_json_report(results, os.path.join(args.output_dir, "full_report.json"))

    print(f"\nResults written to {args.output_dir}/")
    print("Recommended deployment model: DecisionTree (lightest, matches paper's 'pruned DTC' guidance).")
    print("Note: precision on Attack is expected to be low -- this model is a TRIGGER for Census daisy-chain")
    print("polling (Phase 4), not a final verdict. Recall is the metric that matters here.")


if __name__ == "__main__":
    main()
