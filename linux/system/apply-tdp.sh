#!/bin/bash
# apply-tdp.sh - Applied on every boot by ryzenadj-tdp.service
# Ryzen 7 4700U TDP profile:
#   slow-limit=35W  (sustained / 28-30s window)
#   fast-limit=45W  (short burst ~1-2s)
#   tctl-temp=95C   (full thermal headroom)
modprobe ryzen_smu 2>/dev/null || true
sleep 1
ryzenadj     --slow-limit=35000     --fast-limit=45000     --tctl-temp=95     --vrm-current=55000     --vrmsoc-current=35000     --vrmmax-current=55000     --vrmsocmax-current=35000     && echo tdp_applied_slow35W_fast45W     || echo ryzenadj_failed
