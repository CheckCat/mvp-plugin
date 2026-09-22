#!/usr/bin/env bash
# h1-cap.sh — check-скрипт гипотезы H1-cap-work-preservation
# (docs/experiments/registry.json): «CAP=30 не теряет работу за швом».
#
# Контракт check-скрипта (lib/experiments.sh, спека §7): env HYP_ID,
# RUN_LABEL, RESULTS_PATH, PLUGIN_ROOT, PROJECT_ROOT; последняя строка
# stdout — {"ok":bool,"reason":str|null,"hint":str|null,"data":object}.
# Запись в results.jsonl делает вызывающий lib/experiments.sh — этот скрипт
# только читает и ничего не пишет.
#
# Источник данных — .mvp/telemetry/events.jsonl (событие task_complete с
# additive-полями arm/segments, Task 8). Задача из .mvp/plan.json намеренно
# НЕ читается: плану неизвестно, к какому рукаву относилась задача (arm —
# поле события, не плана), так что «доля дошедших до finalize по рукаву»
# посчитать оттуда нечем без дополнительной разметки. Решающее правило
# поэтому сравнивает напрямую средние dispatches рукава и контроля — если
# CAP=30 не дорожает диспатчами сильнее порога, работа не потеряна.
set -u
python3 <<'PY'
import json, os

project_root = os.environ.get("PROJECT_ROOT", ".")
events_path = os.path.join(project_root, ".mvp/telemetry/events.jsonl")

arm_disp, control_disp, arm_seg = [], [], []
try:
    with open(events_path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("event") != "task_complete":
                continue
            arm = ev.get("arm")
            disp = ev.get("dispatches")
            if not isinstance(disp, (int, float)):
                continue
            if arm == "cap30":
                arm_disp.append(disp)
                seg = ev.get("segments")
                if isinstance(seg, (int, float)):
                    arm_seg.append(seg)
            elif arm == "control":
                control_disp.append(disp)
except FileNotFoundError:
    pass

n_arm = len(arm_disp)
n_control = len(control_disp)
mean_disp_arm = (sum(arm_disp) / n_arm) if n_arm else None
mean_disp_control = (sum(control_disp) / n_control) if n_control else None
mean_segments = (sum(arm_seg) / len(arm_seg)) if arm_seg else None

verdict = None
reason = None
if n_arm < 8:
    reason = "недостаточно данных: n_arm=%d < 8" % n_arm
elif n_control < 1:
    reason = "нет контрольной группы: n_control=0, сравнивать не с чем"
elif mean_disp_arm <= 1.53 * mean_disp_control:
    verdict = "confirmed"
elif mean_disp_arm > 2.5 * mean_disp_control:
    verdict = "refuted"
else:
    reason = (
        "n_arm=%d >= 8, но mean_disp_arm=%.3f не укладывается ни в "
        "confirmed (<= 1.53 * mean_disp_control), ни в refuted "
        "(> 2.5 * mean_disp_control=%.3f)"
        % (n_arm, mean_disp_arm, mean_disp_control)
    )

value = {
    "n_arm": n_arm,
    "n_control": n_control,
    "mean_disp_arm": mean_disp_arm,
    "mean_disp_control": mean_disp_control,
    "mean_segments": mean_segments,
}
print(json.dumps({"ok": True, "reason": reason, "hint": None,
                  "data": {"value": value, "verdict": verdict}}))
PY
