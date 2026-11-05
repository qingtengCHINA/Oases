# Interface sounds

`OasesChat/Resources/Sounds/ui_*.caf` are rendered offline from
[sensory-ui](https://github.com/SatyamVyas04/sensory-ui) (MIT, Satyam Vyas), commit
`d82a67d34d5ab6e86eabf1a196d4ed55e6f3eebb`, "Soft" instrument. sensory-ui synthesises its sounds
with Web Audio and ships no audio files, so the cues are rendered once and committed.

| Cue | sensory-ui role | Pack |
|---|---|---|
| send | navigation.forward | Soft, short reverb (0.4 s, decay 3, mix 0.12) |
| reply_done | notification.info | Soft (reverb 0.8 s, decay 2.5, mix 0.2) |
| task_done | notification.success | Soft |
| error | notification.error | Soft with the pack's own error override |
| attention | notification.warning | Soft |
| toggle | interaction.toggle | Soft, short reverb |
| trash | overlay.collapse | Soft, short reverb |
| copy | navigation.tab | Soft, short reverb |

Re-render (only if the cues must change; the reverb uses a seeded random so renders repeat):

1. Get the sensory-ui sources (only `components/ui/sensory-ui/sounds` is needed).
2. `node scripts/sounds/bundle.mjs <sensory-ui>/components/ui/sensory-ui/sounds <work>/render.html`
3. `node scripts/sounds/cdp-render.mjs <work>/render.html <work>/raw` (headless Chrome)
4. `python3 -I scripts/sounds/postprocess.py <work>`, then copy the used `caf/ui_*.caf` files.
