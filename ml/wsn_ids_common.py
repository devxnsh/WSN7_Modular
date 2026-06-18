"""Shared helpers for ML_IDS_PLAN.md Phase 5 training scripts.

Used by both train_global_model.py (Sink-Observed dataset) and
train_local_model.py (Local Telemetry dataset). Kept deliberately small:
CSV loading, encoding, metric/plot helpers -- no model logic here, since
the two scripts intentionally use different models/feature sets.
"""
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from imblearn.over_sampling import SMOTE
from imblearn.under_sampling import RandomUnderSampler
from sklearn.metrics import (
    ConfusionMatrixDisplay,
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
)
from sklearn.preprocessing import LabelEncoder
from sklearn.utils.class_weight import compute_sample_weight


class LGBMMulticlassWrapper:
    """sklearn-compatible wrapper around lightgbm.LGBMClassifier for
    multiclass training with imbalanced classes. LightGBM (and XGBoost)
    don't accept class_weight='balanced' the way sklearn's own estimators
    do for multiclass, and want integer-encoded labels -- this wrapper
    handles both transparently so it drops into the same
    fit(X, y) / predict(X) / feature_importances_ interface as every other
    model in these scripts, including evaluate_model() and
    save_feature_importance().
    """

    def __init__(self, **lgbm_kwargs):
        import lightgbm as lgb
        self.model = lgb.LGBMClassifier(**lgbm_kwargs)
        self.label_encoder = LabelEncoder()

    def fit(self, X, y):
        y_enc = self.label_encoder.fit_transform(y)
        sample_weight = compute_sample_weight("balanced", y_enc)
        self.model.fit(X, y_enc, sample_weight=sample_weight)
        return self

    def predict(self, X):
        return self.label_encoder.inverse_transform(self.model.predict(X))

    @property
    def feature_importances_(self):
        return self.model.feature_importances_


def load_dataset(csv_path: str) -> pd.DataFrame:
    """Load a *_dataset.csv produced by WSN_Attack_Demo.m."""
    df = pd.read_csv(csv_path)
    if "AttackTypeName" not in df.columns:
        raise ValueError(f"{csv_path} has no AttackTypeName column -- wrong file?")
    return df


def encode_categoricals(df: pd.DataFrame, columns: list) -> pd.DataFrame:
    """One-hot encode the given low-cardinality categorical columns."""
    present = [c for c in columns if c in df.columns]
    if not present:
        return df
    return pd.get_dummies(df, columns=present)


def resample_training_data(X_train, y_train, target_count: int = 2000, seed: int = 42,
                            max_oversample_ratio: float = 10.0):
    """Rebalance the TRAINING split only (never call on test data -- test
    must stay at the real deployment-like distribution for honest metrics).

    Combines undersampling of the majority (Normal) class with SMOTE
    oversampling of minority classes, both toward a shared target. The
    actual per-class target is capped at max_oversample_ratio times that
    class's real (pre-resampling) count: blindly hitting a large fixed
    target (e.g. 2000) when a class only has ~70 real training rows means
    >95% of that class becomes SMOTE-interpolated synthetic data, which
    measurably hurt accuracy in testing (global-model minority F1 dropped
    from ~0.5 to ~0.05 at target=2000 with 53-80 real minority rows) --
    capping the ratio keeps the synthetic fraction bounded regardless of
    how small the real minority count is.
    """
    counts = y_train.value_counts()
    classes = counts.index.tolist()
    effective_target = {c: min(target_count, int(counts[c] * max_oversample_ratio)) for c in classes}

    # Step 1: undersample any class above its effective target (typically just Normal)
    under_strategy = {c: effective_target[c] for c in classes if counts[c] > effective_target[c]}
    if under_strategy:
        rus = RandomUnderSampler(sampling_strategy=under_strategy, random_state=seed)
        X_train, y_train = rus.fit_resample(X_train, y_train)
        counts = y_train.value_counts()

    # Step 2: SMOTE-oversample any class below its effective target.
    # k_neighbors must be < the smallest minority class's sample count.
    over_strategy = {c: effective_target[c] for c in classes if counts[c] < effective_target[c]}
    if over_strategy:
        min_minority = min(counts[c] for c in over_strategy)
        k_neighbors = max(1, min(5, min_minority - 1))
        smote = SMOTE(sampling_strategy=over_strategy, random_state=seed, k_neighbors=k_neighbors)
        X_train, y_train = smote.fit_resample(X_train, y_train)

    return X_train, y_train


def class_distribution(df: pd.DataFrame, label_col: str = "AttackTypeName") -> pd.DataFrame:
    counts = df[label_col].value_counts()
    dist = counts.rename_axis("AttackTypeName").reset_index(name="Count")
    dist["Fraction"] = dist["Count"] / dist["Count"].sum()
    return dist


def evaluate_model(model, X_test, y_test, class_names: list) -> dict:
    """Run predictions and compute accuracy / per-class F1 / confusion matrix."""
    y_pred = model.predict(X_test)
    acc = accuracy_score(y_test, y_pred)
    report = classification_report(
        y_test, y_pred, labels=class_names, output_dict=True, zero_division=0
    )
    f1_per_class = f1_score(y_test, y_pred, labels=class_names, average=None, zero_division=0)
    cm = confusion_matrix(y_test, y_pred, labels=class_names)
    return {
        "accuracy": acc,
        "report": report,
        "f1_per_class": dict(zip(class_names, f1_per_class.tolist())),
        "confusion_matrix": cm,
    }


def save_confusion_matrix(cm: np.ndarray, class_names: list, out_prefix: str) -> None:
    """Write confusion matrix as both CSV and PNG."""
    pd.DataFrame(cm, index=class_names, columns=class_names).to_csv(f"{out_prefix}.csv")

    fig, ax = plt.subplots(figsize=(max(6, len(class_names) * 1.1), max(5, len(class_names))))
    disp = ConfusionMatrixDisplay(confusion_matrix=cm, display_labels=class_names)
    disp.plot(ax=ax, cmap="Blues", xticks_rotation=45, colorbar=False)
    fig.tight_layout()
    fig.savefig(f"{out_prefix}.png", dpi=150)
    plt.close(fig)


def save_feature_importance(model, feature_names: list, out_prefix: str) -> None:
    """Write RFC/tree feature importances as CSV and a horizontal bar PNG."""
    if not hasattr(model, "feature_importances_"):
        return
    importances = model.feature_importances_
    order = np.argsort(importances)[::-1]
    names_sorted = [feature_names[i] for i in order]
    vals_sorted = importances[order]

    pd.DataFrame({"Feature": names_sorted, "Importance": vals_sorted}).to_csv(
        f"{out_prefix}.csv", index=False
    )

    fig, ax = plt.subplots(figsize=(8, max(4, len(feature_names) * 0.35)))
    ax.barh(names_sorted[::-1], vals_sorted[::-1], color="#4472C4")
    ax.set_xlabel("Importance")
    ax.set_title("Feature Importance")
    fig.tight_layout()
    fig.savefig(f"{out_prefix}.png", dpi=150)
    plt.close(fig)


def save_accuracy_comparison(results_by_model: dict, out_path: str) -> None:
    """results_by_model: {model_name: {"accuracy": float, ...}} -> CSV table."""
    rows = [{"Model": name, "Accuracy": r["accuracy"]} for name, r in results_by_model.items()]
    pd.DataFrame(rows).to_csv(out_path, index=False)


def save_precision_recall(results_by_model: dict, class_names: list, out_path: str) -> None:
    """Precision/recall per class per model -- accuracy/F1 alone hide the
    precision-recall asymmetry that matters most under heavy class
    imbalance (e.g. a model can have terrible precision but still be
    useful as a high-recall trigger for a downstream corroboration step).
    """
    rows = []
    for name, r in results_by_model.items():
        for cls in class_names:
            stats = r["report"].get(str(cls), {})
            rows.append({
                "Model": name, "Class": cls,
                "Precision": stats.get("precision"), "Recall": stats.get("recall"),
                "F1": stats.get("f1-score"), "Support": stats.get("support"),
            })
    pd.DataFrame(rows).to_csv(out_path, index=False)


def save_per_class_f1(results_by_model: dict, out_path: str) -> None:
    """results_by_model: {model_name: {"f1_per_class": {...}}} -> wide CSV table."""
    df = pd.DataFrame({name: r["f1_per_class"] for name, r in results_by_model.items()})
    df.index.name = "AttackTypeName"
    df.to_csv(out_path)


def save_json_report(results_by_model: dict, out_path: str) -> None:
    serializable = {
        name: {
            "accuracy": r["accuracy"],
            "f1_per_class": r["f1_per_class"],
            "classification_report": r["report"],
        }
        for name, r in results_by_model.items()
    }
    with open(out_path, "w") as f:
        json.dump(serializable, f, indent=2)


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)
