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
static const char *command_names;
static char *prompt(EditLine *editor) { return (char *)prompt_text; }
static unsigned char insert_draft(EditLine *editor, int key) {
    if (pending) { el_insertstr(editor, pending); pending = NULL; }
    return CC_REFRESH;
}
static unsigned char complete_command(EditLine *editor, int key) {
    const LineInfo *line = el_line(editor);
    size_t prefix = (size_t)(line->cursor - line->buffer);
    if (!command_names || prefix == 0 || line->buffer[0] != '/' || line->cursor != line->lastchar) return CC_REFRESH_BEEP;
    for (size_t i = 0; i < prefix; i++) if (line->buffer[i] == ' ' || line->buffer[i] == '\n' || line->buffer[i] == '\t') return CC_REFRESH_BEEP;
    const char *match = NULL;
    size_t match_length = 0, count = 0;
    for (const char *p = command_names; *p;) {
        const char *end = strchr(p, '\n');
        size_t length = end ? (size_t)(end - p) : strlen(p);
        if (length >= prefix && strncmp(p, line->buffer, prefix) == 0) { count++; match = p; match_length = length; }
        p += length; if (*p) p++;
    }
    if (count == 1) {
        char *suffix = malloc(match_length - prefix + 2);
        if (!suffix) return CC_ERROR;
        memcpy(suffix, match + prefix, match_length - prefix);
        suffix[match_length - prefix] = ' '; suffix[match_length - prefix + 1] = 0;
        el_insertstr(editor, suffix); free(suffix);
        return CC_REFRESH;
    }
    if (count == 0) return CC_REFRESH_BEEP;
    fputc('\n', stderr);
    for (const char *p = command_names; *p;) {
        const char *end = strchr(p, '\n');
        size_t length = end ? (size_t)(end - p) : strlen(p);
        if (length >= prefix && strncmp(p, line->buffer, prefix) == 0) { fwrite(p, 1, length, stderr); fputc('\n', stderr); }
        p += length; if (*p) p++;
    }
    return CC_REDISPLAY;
}
// Called serially by the interactive pf loop only. No persistent command history.
char *pf_readline(const char *text, const char *initial, const char *commands) {
    setlocale(LC_CTYPE, "");
    if (!cleanup_registered) { atexit(restore_terminal); cleanup_registered = 1; }
    terminal_saved = tcgetattr(STDIN_FILENO, &saved_terminal) == 0;
    prompt_text = text; pending = initial; command_names = commands;
    EditLine *editor = el_init("pf", stdin, stderr, stderr);
    if (!editor) { restore_terminal(); return NULL; }
    el_set(editor, EL_PROMPT, prompt);
    el_set(editor, EL_EDITOR, "emacs");
    el_set(editor, EL_ADDFN, "complete-command", "Complete a slash command", complete_command);
    el_set(editor, EL_BIND, "^I", "complete-command", NULL);
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
    el_end(editor); restore_terminal(); pending = NULL; prompt_text = NULL; command_names = NULL;
    return line;
}
#else
char *pf_readline(const char *prompt, const char *initial, const char *commands) { return 0; }
#endif
