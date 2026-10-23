// Save import: an emulator's save for the game (Ryujinx, yuzu and its forks, Checkpoint / JKSV backups), as a folder or a .zip.
#import <Foundation/Foundation.h>

// Looks for the folder holding Mii.sav / Player.sav / Map.sav inside `source` (a folder or a .zip, any depth, so the
// emulator's whole save folder works), and makes it the save of the island in `slotDir`. The island's old save is kept
// beside it as save-before-import-<time>. Returns nil on success (*files = files copied), else a message for the user.
NSString *nx_save_import(NSString *source, NSString *slotDir, int *files);
