#include "PiLineEditor.h"
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
#include <histedit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <termios.h>
#include <unistd.h>
static struct termios saved_terminal;
static int terminal_saved;
static int cleanup_registered;
static void restore_terminal(void) {
    if (terminal_saved) { tcsetattr(STDIN_FILENO, TCSANOW, &saved_terminal); terminal_saved = 0; }
}
static const char *pending;
static const char *prompt_text;
static char *prompt(EditLine *editor) { return (char *)prompt_text; }
static unsigned char insert_draft(EditLine *editor, int key) {
    if (pending) { el_insertstr(editor, pending); pending = NULL; }
    return CC_REFRESH;
}
// Called serially by the interactive pf loop only. No persistent command history.
char *pf_readline(const char *text, const char *initial) {
    setlocale(LC_CTYPE, "");
    if (!cleanup_registered) { atexit(restore_terminal); cleanup_registered = 1; }
    terminal_saved = tcgetattr(STDIN_FILENO, &saved_terminal) == 0;
    prompt_text = text; pending = initial;
    EditLine *editor = el_init("pf", stdin, stderr, stderr);
    if (!editor) { restore_terminal(); return NULL; }
    el_set(editor, EL_PROMPT, prompt);
    el_set(editor, EL_EDITOR, "emacs");
    // Queue an editor action, not the draft's keystrokes. Embedded newlines stay
    // editable text and cannot submit a historical message automatically.
    if (initial && *initial) {
        el_set(editor, EL_ADDFN, "restore-draft", "Restore the selected message", insert_draft);
        el_set(editor, EL_BIND, "^_", "restore-draft", NULL);
        el_push(editor, "\037");
    }
    // Prepare before drawing a queued draft: immediate editing keys must not be
    // consumed by the terminal's canonical input processing.
    el_set(editor, EL_PREP_TERM, 1);
    int length = 0;
    const char *input = el_gets(editor, &length);
    char *line = input && length > 0 ? strndup(input, input[length - 1] == '\n' ? length - 1 : length) : NULL;
    el_end(editor); restore_terminal(); pending = NULL; prompt_text = NULL;
    return line;
}
#else
char *pf_readline(const char *prompt, const char *initial) { return 0; }
#endif
