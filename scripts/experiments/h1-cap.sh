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
# НЕ читается для «доли дошедших до finalize»: плану неизвестно, к какому
# рукаву относилась задача (arm — поле события, не плана), так что эту
# долю посчитать оттуда нечем без дополнительной разметки. Решающее правило
# поэтому сравнивает напрямую средние dispatches рукава и контроля — если
# CAP=30 не дорожает диспатчами сильнее порога, работа не потеряна.
#
# ОДНАКО (fix round 1, Finding 1): .mvp/plan.json читается ДЛЯ СТРАХОВКИ.
# task_complete не порождается для задачи, которую рукав потерял — упёрлась,
# запарковалась, осталась status=="failed" — такая задача просто не попадает
# в выборку dispatches вовсе. Сценарий «рукав тихо роняет часть задач, а
# оставшиеся отрабатывают нормально» дал бы confirmed по чистой арифметике
# dispatches, хотя это ровно тот случай, который гипотеза обязана
# опровергнуть. Поэтому: план прогона содержит failed-задачу -> confirmed
# понижается до null (refuted трогать нельзя — отрицательный вывод от такой
# страховки не страдает, он и так означает «не подтвердилось»).
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

# Fix round 1, Finding 2: n_control=1 — одна точка выдаваемая за контроль,
# это шум, а не сравнение. MIN_CONTROL=4 — половина порога рукава (n_arm>=8):
# достаточно, чтобы один выброс не определял среднее контроля, не требуя
# удваивать длину прогона симметричной восьмёркой.
MIN_CONTROL = 4

verdict = None
reason = None
if n_arm < 8:
    reason = "недостаточно данных: n_arm=%d < 8" % n_arm
elif n_control < MIN_CONTROL:
    reason = (
        "недостаточно контрольных наблюдений: n_control=%d < %d — "
        "сравнение с таким контролем это шум, не вердикт" % (n_control, MIN_CONTROL)
    )
elif mean_disp_arm <= 1.53 * mean_disp_control:
    verdict = "confirmed"
    reason = (
        "mean_disp_arm=%.3f <= 1.53 * mean_disp_control=%.3f (порог %.3f) "
        "при n_arm=%d, n_control=%d — рукав не дороже контроля"
        % (mean_disp_arm, mean_disp_control, 1.53 * mean_disp_control, n_arm, n_control)
    )
elif mean_disp_arm > 2.5 * mean_disp_control:
    verdict = "refuted"
    reason = (
        "mean_disp_arm=%.3f > 2.5 * mean_disp_control=%.3f (порог %.3f) "
        "при n_arm=%d, n_control=%d — рукав разрушительно дороже контроля"
        % (mean_disp_arm, mean_disp_control, 2.5 * mean_disp_control, n_arm, n_control)
    )
else:
    reason = (
        "n_arm=%d >= 8, n_control=%d >= %d, но mean_disp_arm=%.3f не укладывается "
        "ни в confirmed (<= 1.53 * mean_disp_control=%.3f), ни в refuted "
        "(> 2.5 * mean_disp_control=%.3f)"
        % (n_arm, n_control, MIN_CONTROL, mean_disp_arm, 1.53 * mean_disp_control, 2.5 * mean_disp_control)
    )

# Finding 1: страховка по потерянным задачам — см. комментарий в шапке файла.
has_failed_task = False
plan_path = os.path.join(project_root, ".mvp/plan.json")
try:
    plan = json.load(open(plan_path))
    has_failed_task = any(
        isinstance(t, dict) and t.get("status") == "failed"
        for t in (plan.get("tasks") or [])
    )
except (FileNotFoundError, ValueError):
    pass

if verdict == "confirmed" and has_failed_task:
    verdict = None
    reason = (
        "в прогоне .mvp/plan.json есть незавершённая (status=failed) задача — "
        "утверждать сохранность работы нельзя: task_complete не порождается для "
        "задачи, которую рукав потерял (упёрлась/запаркована), такая потеря не "
        "видна метрике dispatches и не должна маскироваться под confirmed"
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
