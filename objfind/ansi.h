//
//  ansi.h
//  objfind
//
//  Created by Ethan Arbuckle on 12/30/24.
//

#ifndef ansi_h
#define ansi_h

#define ANSI_CLEAR_LINE "\033[2K\r"
#define ANSI_RESET   "\x1b[0m"
#define ANSI_BOLD    "\x1b[1m"
#define ANSI_RED     "\x1b[31m"
#define ANSI_GREEN   "\x1b[32m"
#define ANSI_YELLOW  "\x1b[33m"
#define ANSI_BLUE    "\x1b[34m"
#define ANSI_MAGENTA "\x1b[35m"
#define ANSI_CYAN    "\x1b[36m"
#define ANSI_WHITE   "\x1b[37m"
#define ANSI_GRAY    "\x1b[90m"

#define BOX_HORIZ      "─"
#define BOX_VERT       "│"
#define BOX_TOP_LEFT   "┌"
#define BOX_TOP_RIGHT  "┐"
#define BOX_BOT_LEFT   "└"
#define BOX_BOT_RIGHT  "┘"
#define BOX_TEE_RIGHT  "├"
#define BOX_CONNECT    "──"

#endif /* ansi_h */
