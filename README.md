# vulpea-journal

A daily journaling interface for [vulpea](https://github.com/d12frosted/vulpea) that integrates seamlessly with [vulpea-ui](https://github.com/d12frosted/vulpea-ui) sidebar.

## What is vulpea-journal?

vulpea-journal brings the power of daily journaling to your vulpea-based note system. Think of it as [org-journal](https://github.com/bastibe/org-journal) rebuilt from the ground up for vulpea, with a modern reactive UI.

**Key features:**

- **Daily notes** - One file per day, automatically created with customizable templates
- **Sidebar widgets** - Calendar, navigation, related notes - all in the vulpea-ui sidebar
- **Calendar integration** - See which days have entries, jump to any date
- **Previous years** - "On this day" view showing what you wrote in past years
- **Zero window management** - Uses vulpea-ui sidebar, no custom layouts to break

## Quick Start

### 1. Install

vulpea-journal requires:
- Emacs 29.1+
- [vulpea](https://github.com/d12frosted/vulpea) 2.0+
- [vulpea-ui](https://github.com/d12frosted/vulpea-ui) 0.1+
- [dash](https://github.com/magnars/dash.el) 2.20+

```elisp
;; With use-package and straight.el
(use-package vulpea-journal
  :straight (:host github :repo "d12frosted/vulpea-journal")
  :after (vulpea vulpea-ui)
  :config
  (vulpea-journal-setup))
```

### 2. Widgets are auto-registered

Journal widgets automatically register with vulpea-ui when you load `vulpea-journal-ui`. They only appear when viewing journal notes.

Default widget order interleaves with vulpea-ui widgets:

| Widget           | Order | Appears...              |
|------------------|-------|-------------------------|
| journal-nav      |    50 | Before stats            |
| stats            |   100 | (vulpea-ui)             |
| journal-calendar |   150 | After stats             |
| outline          |   200 | (vulpea-ui)             |
| backlinks        |   300 | (vulpea-ui)             |
| created-today    |   350 | After backlinks         |
| previous-years   |   360 | After created-today     |
| links            |   400 | (vulpea-ui)             |

To customize the order, see [Widget Order Configuration](#widget-order-configuration) below.

### 3. Add a keybinding

```elisp
(global-set-key (kbd "C-c j") #'vulpea-journal)
```

### 4. Start journaling!

Press `C-c j` to open today's journal. The sidebar will show journal-specific widgets.

## How It Works

### Journal Notes

Journal notes are regular vulpea notes identified by a tag (default: `"journal"`). Each note has:

- A **file path** based on the date (e.g., `journal/2025-12-08.org`)
- A **title** based on the date (e.g., `2025-12-08 Sunday`)
- A **CREATED property** storing the date for querying

When you call `vulpea-journal`, it:
1. Finds or creates the note for that date
2. Opens it in your main window
3. Shows the vulpea-ui sidebar with journal widgets

### Sidebar Integration

vulpea-journal doesn't create its own windows. Instead, it provides **widgets** that plug into vulpea-ui's sidebar system. This means:

- No window management bugs
- Consistent UI with the rest of vulpea-ui
- Widgets automatically appear/disappear based on what you're viewing

Journal widgets check if the current note is a journal entry. When you view a non-journal note, they simply hide themselves.

## Configuration

### Template

Customize how journal notes are created:

```elisp
(setq vulpea-journal-default-template
      '(:file-name "journal/%Y-%m-%d.org"    ; File path (strftime format)
        :title "%Y-%m-%d %A"                  ; Note title (strftime format)
        :tags ("journal")                     ; Tags (first one identifies journals)
        :head "#+created: %<[%Y-%m-%d]>"      ; Header content
        :body "* Morning\n\n* Evening\n"))    ; Initial body
```

**Important:** The `:file-name` and `:title` use `strftime` format because they're expanded for the *target date*, not the current time. When you open the journal for December 25th, the file will be `journal/2025-12-25.org` regardless of today's date.

Other keys (`:head`, `:body`) use vulpea's `%<format>` syntax and are expanded at creation time.

### Dynamic Templates

For more control, use a function:

```elisp
(setq vulpea-journal-default-template
      (lambda (date)
        (let ((weekday (format-time-string "%u" date)))
          (list
           :file-name "journal/%Y-%m-%d.org"
           :title (format-time-string "%Y-%m-%d %A" date)
           :tags '("journal")
           :head "#+created: %<[%Y-%m-%d]>"
           :body (if (member weekday '("6" "7"))
                     "* Weekend\n\n"
                   "* Work\n\n* Personal\n")))))
```

### Calendar Widget

```elisp
;; Start week on Sunday (0) or Monday (1, default)
(setq vulpea-journal-ui-calendar-week-start 1)
```

### Created Today Widget

```elisp
;; Include journal notes in the "created today" list
(setq vulpea-journal-ui-created-today-exclude-journal nil)  ; default: t
```

### Previous Years Widget

```elisp
;; How many years to look back
(setq vulpea-journal-ui-previous-years-count 5)  ; default: 5

;; Characters to show in preview
(setq vulpea-journal-ui-previous-years-preview-chars 256)

;; Hide org drawers in preview
(setq vulpea-journal-ui-previous-years-hide-drawers t)  ; default: t

;; Start with previews expanded
(setq vulpea-journal-ui-previous-years-expanded t)  ; default: t
```

### Widget Order Configuration

Customize where journal widgets appear relative to vulpea-ui widgets:

```elisp
(setq vulpea-journal-ui-widget-orders
      '((nav . 50)              ; before stats (100)
        (calendar . 150)        ; after stats, before outline (200)
        (created-today . 350)   ; after backlinks (300)
        (previous-years . 360)))
```

Example: Move calendar before stats:

```elisp
(use-package vulpea-journal
  :custom
  (vulpea-journal-ui-widget-orders
   '((nav . 50)
     (calendar . 90)            ; now before stats
     (created-today . 350)
     (previous-years . 360))))
```

Reference orders for vulpea-ui widgets: stats=100, outline=200, backlinks=300, links=400.

## Commands

| Command | Description |
|---------|-------------|
| `vulpea-journal` | Open today's journal (or specify date programmatically) |
| `vulpea-journal-today` | Open today's journal |
| `vulpea-journal-date` | Prompt for a date and open its journal |
| `vulpea-journal-next` | Go to next journal entry |
| `vulpea-journal-previous` | Go to previous journal entry |
| `vulpea-journal-setup` | Enable calendar integration |

## Calendar Integration

After calling `vulpea-journal-setup`, the Emacs calendar gains journal superpowers:

| Key | Action |
|-----|--------|
| `j` | Open journal for date at point |
| `]` | Jump to next journal entry |
| `[` | Jump to previous journal entry |

Days with journal entries are highlighted in the calendar.

## Widgets Reference

### vulpea-journal-widget-nav

Shows the current journal date and navigation buttons:

```
Journal: 2025-12-08 Sunday
[< Prev] [Today] [Next >]
```

Clicking **Prev/Next** navigates by one day (creating the entry if needed).
Clicking **Today** jumps to today's journal.

### vulpea-journal-widget-calendar

Interactive month calendar:

```
Calendar
[<] December 2025 [>]
Mo Tu We Th Fr Sa Su
 1  2  3  4  5  6  7
 8· 9 10 11 12 13 14
...
```

- **Bold** = today
- **Highlighted** = selected date
- **Dot (·)** = has journal entry
- Click any date to open its journal

Use `<` and `>` to navigate months without changing the selected date.

### vulpea-journal-widget-created-today

Lists all notes created on the journal's date (from the CREATED property):

```
▾ Created Today (3)
  09:15 Meeting notes #work
  14:30 Project ideas #projects
  16:45 Book recommendation #reading
```

Click a note to visit it. Times come from the CREATED property timestamp.

### vulpea-journal-widget-previous-years

Shows journal entries from the same date in previous years:

```
▾ This Day in Previous Years (2)
  ▾ 2024-12-08 (1 year ago)
    Had a great conversation with...
  ▸ 2023-12-08 (2 years ago)
```

Click the date to visit that journal. Click `▸`/`▾` to expand/collapse the preview.

## Tips & Tricks

### Open journal on Emacs startup

```elisp
(add-hook 'emacs-startup-hook #'vulpea-journal)
```

### Weekly review workflow

Use `vulpea-journal-dates-in-range` to query entries:

```elisp
(defun my/journal-this-week ()
  "Get all journal dates from this week."
  (let* ((today (current-time))
         (dow (string-to-number (format-time-string "%u" today)))
         (start (time-subtract today (days-to-time (1- dow))))
         (end (time-add start (days-to-time 7))))
    (vulpea-journal-dates-in-range start end)))
```

### Custom journal tag

If you want a different tag than `"journal"`:

```elisp
(setq vulpea-journal-default-template
      '(:file-name "daily/%Y-%m-%d.org"
        :title "%Y-%m-%d %A"
        :tags ("daily-note")  ; First tag is used for identification
        :head "#+created: %<[%Y-%m-%d]>"))
```

## Troubleshooting

### Widgets don't appear in sidebar

1. Ensure `vulpea-journal-ui` is loaded (widgets auto-register on load)
2. Check that you're viewing a journal note (has the journal tag)
3. Try `M-x vulpea-ui-sidebar-refresh`

### Date extraction fails

vulpea-journal extracts dates from the **CREATED property**. Ensure your template includes:

```elisp
:head "#+created: %<[%Y-%m-%d]>"
```

Supported formats:
- `[2025-12-08]`
- `[2025-12-08 08:54]`
- `2025-12-08`

### Calendar marks don't appear

Call `vulpea-journal-setup` in your config, or manually:

```elisp
(add-hook 'calendar-today-visible-hook #'vulpea-journal-calendar-mark-entries)
(add-hook 'calendar-today-invisible-hook #'vulpea-journal-calendar-mark-entries)
```

### Old journal entries not found

If you have existing journal notes without the CREATED property, vulpea-journal won't find them for queries. The note itself will work fine if opened directly.

To add CREATED properties to existing notes, you can use a script or manually add them.

## API Reference

### Functions

```elisp
;; Note identification
(vulpea-journal-note-p note)        ; Is NOTE a journal note?
(vulpea-journal-note-date note)     ; Extract date from journal NOTE

;; Note retrieval
(vulpea-journal-note date)          ; Get/create journal for DATE
(vulpea-journal-find-note date)     ; Find existing journal (no create)

;; Queries
(vulpea-journal-all-dates)          ; All dates with journals
(vulpea-journal-dates-in-month m y) ; Journals in month M of year Y
(vulpea-journal-dates-in-range a b) ; Journals between dates A and B
(vulpea-journal-notes-for-date-across-years date n)  ; Same date in past N years
```

### Faces

- `vulpea-journal-calendar-entry-face` - Calendar days with entries
- `vulpea-journal-ui-widget-title` - Widget headers
- `vulpea-journal-ui-calendar-date` - Regular calendar days
- `vulpea-journal-ui-calendar-today` - Today in calendar
- `vulpea-journal-ui-calendar-entry` - Days with entries in widget
- `vulpea-journal-ui-calendar-selected` - Selected day in widget

## Contributing

Contributions welcome! Please open issues and PRs on GitHub.

## License

GPLv3. See [LICENSE](LICENSE) for details.
