#!/usr/bin/env bash
# Look At Me's on-box visual QA capture: dot-game's shot tool runs tools/visual_qa.gd (dot-game docs/visual-qa.md).
# Normally started by dot-game's driver:
#   bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh -- [--only person_a,witch] [--clips idle,walk]
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
