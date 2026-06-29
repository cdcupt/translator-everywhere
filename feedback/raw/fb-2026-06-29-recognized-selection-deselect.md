# fb-2026-06-29-recognized-selection-deselect

- **Source:** field-note (Erik, in conversation)
- **Date:** 2026-06-29
- **Screenshot:** `./fb-2026-06-29-recognized-selection-deselect.png`

## Verbatim report

> Regarding Translate Everywhere, there are issues when I select a recognized word.
> As you see, when I try to click somewhere to unselect the word, it doesn't work.
> I can only unselect the word if I click a specific area.
>
> I think it's a small problem, but can you fix it? Usually, when I select words or
> content on the pop-up window and I click anywhere I want, I can unselect them.

## Context

Result panel showing a translation of "BandwagonHOST". The "Recognized" text
(`BandwagonHOST`) is selected/highlighted. Clicking elsewhere in the window does
not clear the selection; only clicking a "specific area" does.

## Root cause (traced)

`macos/Sources/UI/ResultPanel.swift` → `scrollableText(...)` builds the
"Translation" and "Recognized" sections as non-editable but **selectable**
`NSTextView`s (`isSelectable = true`, lines ~570–593). When text is selected and
the user clicks on any non-text chrome (the captions, header row, language bar, or
empty panel area), nothing resigns first responder or clears the text view's
`selectedRange`, so the (inactive) selection highlight persists. The selection
only clears when the click lands on the *other* selectable `NSTextView`, which is
the "specific area" the user found.

## Expected behaviour

Standard macOS popup behaviour: clicking anywhere outside the selected text (blank
panel area / chrome) clears the selection.

## Likely fix direction (for bpl)

In `ResultPanel`, clear text selection on a background click — e.g. on the panel's
content view, intercept `mouseDown` (or attach an `NSClickGestureRecognizer`) and
call `panel.makeFirstResponder(nil)` and/or reset each text view's `selectedRange`
to empty. Keep text still selectable; only deselect-on-outside-click is added.
