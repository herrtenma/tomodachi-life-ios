// What the launcher does online: the news / update check (a news.json on the GitHub main branch), feedback and crash
// reports (to the feedback worker, feedback/), and the markers that tell the next launch the last session crashed.
#import <Foundation/Foundation.h>

// ---- News and updates ----
// news.json: {"latest": "0.1.0", "url": "release page", "entries": [{"version", "date", "title", "notes": ["...", ...]}]}.
// Calls `done` on the main queue with the newest copy, else the cached one, else nil. Never blocks, never shows an error.
void nx_news_fetch(void (^done)(NSDictionary *news));
// Is news[@"latest"] newer than this build (CFBundleShortVersionString)?
BOOL nx_news_update_available(NSDictionary *news);
NSString *nx_app_version(void);

// ---- Feedback ----
// kind: @"crash", @"bug" or @"idea". The game log (with $HOME shortened to ~; no saves) goes along when withLog is set;
// after a crash the previous session's log (nxrt-prev.log) too. `done` gets nil on success, else a message. Users are
// limited to 3 reports an hour on the phone (the server limits per device, per network and per day as well).
void nx_feedback_send(NSString *kind, NSString *message, NSString *contact, BOOL withLog, void (^done)(NSString *error));

// ---- Crash markers (files in the working folder) ----
// nx_session_begin: keeps the last log as nxrt-prev.log, then marks "running". Call before the log is reopened.
// nx_session_end: the app went to the background or quit: not a crash. The crash handler writes .crashed itself.
void nx_session_begin(void);
void nx_session_end(void);
void nx_session_resume(void);        // back in the foreground: running again
BOOL nx_last_session_crashed(void);   // set by nx_session_begin, from the markers the previous session left
void nx_crash_marker_write(void);     // async-signal-safe
