"""ML_IDS_PLAN.md Phase 5: train the global (Sink-tier) IDS model.

Consumes logs/sink_dataset.csv -- the Sink-Observed dataset, built purely
from what WSN_Sink.m can actually see (registry state, reporting gaps,
reroutes), not omniscient per-node ground truth. Trains a class-weighted
Decision Tree and Random Forest (mirroring the paper's Sink-tier section)
plus Extra-Trees and LightGBM classifiers, on genuinely Sink-observable
signals. The Sink has no compute/battery constraint (per the paper,
"compute is not the bottleneck" at this tier), so a trial-and-error pass
across several ensemble methods was run: tuned RandomForest,
HistGradientBoosting, ExtraTrees, XGBoost, and LightGBM. LightGBM won
(macro-F1 0.61 baseline -> 0.79); ExtraTrees (0.74) is kept too since it
was the first clear improvement found and remains a useful comparison
point -- see AI_ENGINE_DEBUG_PROMPT.md for the full trial-and-error log.

Usage:
    python train_global_model.py --csv ../logs/sink_dataset.csv
"""
import argparse
import os

from sklearn.ensemble import ExtraTreesClassifier, RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.tree import DecisionTreeClassifier

from wsn_ids_common import (
    LGBMMulticlassWrapper,
    class_distribution,
    encode_categoricals,
    ensure_dir,
    evaluate_model,
    load_dataset,
    resample_training_data,
    save_accuracy_comparison,
    save_confusion_matrix,
    save_feature_importance,
    save_json_report,
    save_per_class_f1,
)

# Columns that are dataset-generation bookkeeping or would leak the label --
# not something a real deployed Sink-side model could see at inference time.
LEAK_OR_META_COLUMNS = [
    "WindowStart", "WindowEnd", "NodeIdx", "NodeHexID",
    "AttackType", "AttackTypeName", "IsMalicious",
    "ScenarioID", "RequestedAttackType", "RequestedIntensity", "AttackerNodeIdx",
]

# RSSIQualityBucket is dropped: WSN_SinkFeatureExport.m buckets it into ~250
# near-continuous "GROUPnnn" categories (a generation-side bug, not a real
# coarse bucket scheme) -- one-hot encoding that would blow up dimensionality
# for no benefit, since ReportedRSSI already carries the same signal as a
# clean numeric column.
DROP_COLUMNS = ["RSSIQualityBucket"]

CATEGORICAL_COLUMNS = ["NodeType"]

LABEL_COL = "AttackTypeName"


def build_features(df):
    df = df.drop(columns=[c for c in DROP_COLUMNS if c in df.columns])

    # Missing reports (NaN) are themselves a signal -- a node the Sink never
    # heard from this window. Treat absence explicitly rather than imputing
    # a plausible-looking value.
    df["ReportsReceived"] = df["ReportsReceived"].fillna(0)
    df["ExpectedReportRatio"] = df["ExpectedReportRatio"].fillna(0)
    df["ReportingGap"] = df["ReportingGap"].fillna(df["ReportingGap"].max() if df["ReportingGap"].notna().any() else 9999)
    df["SelfReportedBattery"] = df["SelfReportedBattery"].fillna(-1)
    df["ReportedRSSI"] = df["ReportedRSSI"].fillna(-1)

    df = encode_categoricals(df, CATEGORICAL_COLUMNS)

    feature_cols = [c for c in df.columns if c not in LEAK_OR_META_COLUMNS]
    X = df[feature_cols]
    y = df[LABEL_COL]
    return X, y, feature_cols


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default="../logs/sink_dataset.csv")
    parser.add_argument("--output-dir", default="results/global")
    parser.add_argument("--test-size", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--resample", action="store_true",
                         help="Undersample Normal / SMOTE the rest before training. Tested and found to "
                              "REGRESS results on this dataset's small minority counts (macro-F1 0.61->0.24) "
                              "-- off by default, kept as an opt-in for when minority counts grow (e.g. after "
                              "Phase 6 dataset rebalancing).")
    parser.add_argument("--resample-target", type=int, default=2000,
                         help="Per-class row count target if --resample is set (capped at 10x each class's real count)")
    args = parser.parse_args()

    ensure_dir(args.output_dir)

    df = load_dataset(args.csv)
    print(f"Loaded {len(df)} rows from {args.csv}")

    dist = class_distribution(df, LABEL_COL)
    dist.to_csv(os.path.join(args.output_dir, "class_distribution.csv"), index=False)
    print(dist.to_string(index=False))

    X, y, feature_cols = build_features(df)
    class_names = sorted(y.unique())

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=args.test_size, random_state=args.seed, stratify=y
    )
    print(f"Train: {len(X_train)} rows, Test: {len(X_test)} rows, Features: {len(feature_cols)}")

    if args.resample:
        X_train, y_train = resample_training_data(X_train, y_train, args.resample_target, args.seed)
        print(f"After resampling (target={args.resample_target}/class): Train: {len(X_train)} rows")
        print(y_train.value_counts().to_string())

    models = {
        "DecisionTree": DecisionTreeClassifier(class_weight="balanced", random_state=args.seed),
        "RandomForest": RandomForestClassifier(
            n_estimators=100, class_weight="balanced", random_state=args.seed, n_jobs=-1
        ),
        "ExtraTrees": ExtraTreesClassifier(
            n_estimators=300, class_weight="balanced", random_state=args.seed, n_jobs=-1
        ),
        "LightGBM": LGBMMulticlassWrapper(n_estimators=300, random_state=args.seed, n_jobs=-1, verbosity=-1),
    }

    results = {}
    for name, model in models.items():
        print(f"\nTraining {name}...")
        model.fit(X_train, y_train)
        res = evaluate_model(model, X_test, y_test, class_names)
        results[name] = res
        print(f"  Accuracy: {res['accuracy']:.4f}")

        prefix = os.path.join(args.output_dir, f"confusion_matrix_{name}")
        save_confusion_matrix(res["confusion_matrix"], class_names, prefix)

        save_feature_importance(
            model, feature_cols, os.path.join(args.output_dir, f"feature_importance_{name}")
        )

    save_accuracy_comparison(results, os.path.join(args.output_dir, "accuracy_comparison.csv"))
    save_per_class_f1(results, os.path.join(args.output_dir, "per_class_f1.csv"))
    save_json_report(results, os.path.join(args.output_dir, "full_report.json"))

    print(f"\nResults written to {args.output_dir}/")


if __name__ == "__main__":
    main()
