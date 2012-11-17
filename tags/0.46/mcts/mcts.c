/*
 * Mud Client Test Server. Copyright 2006, 2007, 2009 Sebastian Andersson
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 *
 *
 * These RFCs are now implemented:
 *   854 - Telnet Protocol Specification.
 *   855 - Telnet Option Specification.
 *   857 - Telnet Echo Option
 *   858 - Telnet Suppress Go Ahead Option
 *   860 - Telnet Timing Mark Option (not correctly implemented).
 *   885 - Telnet End Of Record Option
 *   1073 - Telnet window size option.
 *   1143 - The Q Method of Implemeneting TELNET Option
 *   1413 - Identification Protocol (half of it anyway).
 * There is some support for the CHARSET option (RFC 2066), but it is not correct.
 *
 *  MCCPv2 - Mud Client Compression Protocol.
 *
 * There is a teststring for vt_tileset patch for NetHack.
 *
 * Compile with:
 *   gcc -g -Wall -DHAVE_ZLIB -lz mcts.c -o mcts
 *
 *   or, if the system doesn't have zlib:
 *
 *   gcc -g -Wall mcts.c -o mcts
 *
 * CHANGES:
 *  v0.35 (unreleased).
 *  Fixed some bugs with the CHARSET implementation. Added so it can ACCEPT a charset as well.
 *  Added test_cc 10, to test Reverse Index. Probably not used much by muds.
 *  Added XXX, to test NetHack's vt_tileset patch's tile output.
 *
 *  v0.34 (2009-01-03):
 *    Added "eall" and "promptall" commands, to test prompt handling in clients.
 *    Fixed incorrect "testcc 8", there was a strange ICH sent, that caused
 *    correct terminals to write the '5' too far to the right.
 *    Added testtext with parameters.
 *    Added "cat" command to send a 'test.txt' file.
 *
 *  v0.33 (2008-12-29):
 *    Renamed the server to MUD client test server; mcts.
 *    Added some code to test iso-8859-1 & utf-8 and word wrapping.
 *    Fixed some cursor movement code. CSI <col> 'H' is probably not legal.
 *    Added a mechanism to set variables and made it possible to turn off
 *    the echoing of telnet options when "nodebug" is set to a value.
 *
 *  v0.32 (2007-12-23):
 *    Added some quick (and incorrect) fixes to get the code to compile
 *    under cygwin.
 *
 *  v0.31 (2007-12-06):
 *    Added support for ident lookups. Not nicly done, but working. ;-)
 *
 *  v0.3 (2007-11-21):
 *    Began to add support for IPv6. Added some more debug info.
 *    Added some comments and cleaned up some of the worst code.
 */

#define VERSION "0.35"

#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/types.h>
#ifndef AIX
#include <sys/file.h>
#endif
#include <time.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/time.h>
#ifdef    NEED_SELECT_H
#include <sys/select.h>
#endif
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#ifndef __SVR4
#include <strings.h>
#endif
#include <ctype.h>
#include <stdbool.h>
#if HAVE_ZLIB
#include <zlib.h>
/* How much code can be compressed at most in one buffer?
 * Usualy a flush will cause the buffer to be smaller anyway.
 */
#define COMP_BUFF_LEN 4096
#endif

/* The maximum length of a received line from the client */
#ifndef LINELEN
#define LINELEN 256
#endif

/* One more than the max number of arguments to a ZMP command. */
#define MAX_ZMP_ARGS 20

 /* Max number of simultanious connections to the server */
#ifndef MAX_FD
#define MAX_FD 10
#endif

 /* How much output to a client can be buffered before the server gives
  * up and closes the connection that client? */
#ifndef DROP_AT
#define DROP_AT 16384
#endif

/* The size of the output buffers.
 * Small values gives frequent allocations, large values
 * vaste memory.
 */
#ifndef BLOCK_SIZE
#define BLOCK_SIZE 4096
#endif

/*
 * Flags to server_write:
 *  SW_DONT_COMPRESS - do not compress this, even if we are
 *                     using a compressed stream
 *  SW_DO_FLUSH - flush the stream after this message.
 *  SW_FINISH - stop the compression after this message.
 *
 *  */
#define SW_DONT_COMPRESS 16
#define SW_DO_FLUSH 32
#define SW_FINISH 64

/* The output queue entries */
typedef struct output_queue {
    struct output_queue *next;
    char text[BLOCK_SIZE];
} output_queue;

/* A state machine for parsing return and linefeed characters when
 * parsing the input.
 * crlf_cr - last character was a CR.
 * crlf_lf - last character was a LF.
 * crlf_normal - last character was another character.
 */
typedef enum crlf_state {
    crlf_normal,
    crlf_cr,
    crlf_lf
} crlf_state;

/* The states the telnet state machine can be in.
 *
 * iac - last character was a IAC.
 * will - last characters were IAC WILL
 * wont - last characters were IAC WONT
 * do - last characters were IAC DO
 * dont - last characters were IAC DONT
 * sb - we're parsing a IAC SB .... IAC SE sequence
 * sbiac - we're parsing a IAC SB .... IAC SE sequence, and the last character was a IAC.
 * normal - user data is being read.
 */
typedef enum telnet_state {
    ts_normal,
    ts_iac,
    ts_will,
    ts_wont,
    ts_do,
    ts_dont,
    ts_sb,
    ts_sbiac,
} telnet_state;

/*
 * These states are from RFC1143 - The Q Method of Implementing TELNET Option
 * and better described there.
 */
typedef enum telnet_option_state {
    tos_NO,
    tos_YES,
    tos_WANTYES_EMPTY,
    tos_WANTNO_EMPTY,
    tos_WANTYES_OPPOSITE,
    tos_WANTNO_OPPOSITE,
} telnet_option_state;

typedef struct key_value {
    struct key_value *next;
    char *key;
    char *value;
} key_value;

/*
 * All the data saved per connected client.
 */
typedef struct Client {
    struct sockaddr_storage address;
    socklen_t address_len;
    output_queue *writebuff;	/* Write buffer. Used for non-blocking IO */
    char holdbuff[LINELEN];		/* The line the client is working on */
#if HAVE_ZLIB
    z_stream *stream;
    Bytef *comp_buffer;
#endif
    telnet_state t_state;
    crlf_state c_state;
    uint16_t mode;		/* misc. telnet modes. */
    uint16_t curr;		/* Where the client is on the line */
    uint16_t position;		/* The x position on the line */
    uint16_t writelen;		/* The number of bytes in the output buffer */
    uint16_t x_size, y_size;
    uint16_t telnet_position;     /* for long options */

    /* telnet options' states:
     * No extended states are supported (state # above 255).
     * */
    telnet_option_state tos_us[256];
    telnet_option_state tos_him[256];

    key_value *variables;
    bool is_connected;
} Clients;

int server_write(int clientnr, const char *mesg, int mesglen, int flags);
void send_zmp(int fd, ...);

/*
 * Client flags:
 * QUITING - the client has disconnected or it has been decided that
 *           it should be thrown out (too much buffered output for example).
 * EORECORS - the client wants EOR after the prompt has been sent.
 * ZMP - ZMP is turned on.
 * INVISIBLE - the server has told the client that it will echo, but it will
 *             not. Used for password entry.
 */
#define SM_QUITING		  1
#define SM_EORECORDS		  4
#define SM_ZMP	        	 32
#define SM_INVISIBLE		 64

/* Various TELNET constants: */
#define SGA   "\003"
#define TM    "\006"
#define TT    "\030"
#define EOR   "\031"
#define NAWS  "\037"
#define LINEMODE "\042"
#define CHARSET "\052"
#define START_TLS "\056"
#define COMPRESS2 "\126"
#define MSP   "\132"
#define MXP   "\133"
#define ZMP   "\135"
#define ENDOFRECORD "\357"
#define DM   "\362"
#define WILL "\373"
#define WONT "\374"
#define DO   "\375"
#define DONT "\376"
#define IAC  "\377"
#define SB   "\372"
#define SE   "\360"

/* MPLEX constants: */
#define MPLEX         "\160"
#define MPLEX_SELECT  "\161"
#define MPLEX_HIDE    "\162"
#define MPLEX_SHOW    "\163"
#define MPLEX_SETSIZE "\164"

/* Various TELNET options: */
#define ECHOc '\001'
#define SGAc '\003'
#define TMc '\006'
#define TTc '\030'
#define EORc '\031'
#define NAWSc '\037'
#define LINEMODEc '\042'
#define CHARSETc '\052'
#define START_TLSc '\056'
#define COMPRESS2c '\126'
#define MSPc '\132'
#define MXPc '\133'
#define ZMPc '\135'
#define MPLEXc '\160'

/* MPLEX subopts */
#define MPLEX_SELECTc  '\161'
#define MPLEX_HIDEc    '\162'
#define MPLEX_SHOWc    '\163'
#define MPLEX_SETSIZEc '\164'

/* More TELNET constants */
#define SEc '\360'
#define SBc '\372'
#define WILLc '\373'
#define WONTc '\374'
#define DOc '\375'
#define DONTc '\376'
#define IACc '\377'

/* select_fd_mask - what fds the select call should listen for,
   read_fd_mask - what fds that need processing
   select_write_fd_mask - what fds the select call should check if they
                          are writeable
   write_fd_mask - what fds that can be written to.
   */
static fd_set select_fd_mask,
       read_fd_mask,
       select_write_fd_mask,
       write_fd_mask;

#ifdef __SVR4
static fd_set exc_fd_mask;
#endif /* __SVR4 */

/* The server's socket that is listening for connections */
static int daemon_fd;

/* The server's TCP port that it is listening on */
static int daemon_port;

/* The highest connected fd */
static int high_fd;

/* All the possibly connected client's data: */
static Clients clients[MAX_FD];


/*
 * A buffer used within methods for creating debug data, this
 * to avoid increasing the needed stack size.
 */
static char debug_buffer[1024];


static const char *
get_var(int fd, const char *key)
{
    key_value *curr = clients[fd].variables;
    while(curr) {
	if(!strcmp(curr->key, key)) {
	    return curr->value;
	}
	curr = curr->next;
    }
    return NULL;
}

/* A simple function to write a C-string to the connected client */
static int
simple_write(int fd, const char *str)
{
    return server_write(fd, str, strlen(str), 0);
}

static void process_line(int fd, char *line);

/*
 * Should we send TELNET debug information to the client?
 */
static bool
should_send_debug(int fd)
{
    return !get_var(fd, "nodebug");
}

/*
 * Write the str to the client and append CR LF
 * Only used for TELNET debug tracing, so that it may easily be disabled.
 */
static int
mputs(int fd, const char *str)
{
    if(should_send_debug(fd)) {
	simple_write(fd, str);
	return simple_write(fd, "\r\n");
    }
    return 0;
}

int
server_init(int port)
    /** Arguments:
     *     port to listen to. If port = 0, pick one at random.
     * Returns: <= 0 if error, daemon_port if okay. */
{
    struct sockaddr_in socket_addr;
    memset(&socket_addr, 0, sizeof(socket_addr));

    daemon_fd = socket(PF_INET, SOCK_STREAM, 0);

    if(daemon_fd < 0)
        return 0;

#ifndef NO_REUSEADDR
    int on = 1;
    if(setsockopt(daemon_fd, SOL_SOCKET, SO_REUSEADDR,
                (char *) &on, sizeof(on)) < 0) {
        /* SO_REUSEADDR makes the socket able to "steal" port numbers */
        close(daemon_fd);
        return 0;
    }
#endif				/* !NO_REUSEADDR */

#ifdef __SVR4
    on = 0;
    if(setsockopt(daemon_fd, SOL_SOCKET, SO_OOBINLINE,
                (char *) &on, sizeof(on)) < 0) {
        perror("setsockopt");
        close(daemon_fd);
        return 0;
    }
#endif				/* __SVR4 */

    socket_addr.sin_family = AF_INET;
    socket_addr.sin_port = htons(port);
    socket_addr.sin_addr.s_addr = INADDR_ANY;

    if(bind(daemon_fd, (struct sockaddr *) &socket_addr, sizeof(socket_addr)) < 0) {
        /* Bind the socket to an adress in the inet family */
        close(daemon_fd);
        return 0;
    }
    if(listen(daemon_fd, 5) < 0) {
        /* make it listen to connecting clients */
        close(daemon_fd);
        return 0;
    }
    FD_ZERO(&select_fd_mask);
    FD_SET(daemon_fd, &select_fd_mask);
    high_fd = daemon_fd + 1;
    daemon_port = ntohs(socket_addr.sin_port);
    return daemon_port;
}

static const char *
get_telnet_option(char c)
{
    switch(c) {
        // TOPT-BIN   Binary Transmission                 0  Std   Rec     856  27
        case 0:
            return "BINARY TRANSMISSION";
            // TOPT-ECHO  Echo                                1  Std   Rec     857  28
        case ECHOc:
            return "ECHO";
            // TOPT-RECN  Reconnection                        2  Prop  Ele     ...
        case 2:
            return "RECONNECTION";
            // TOPT-SUPP  Suppress Go Ahead                   3  Std   Rec     858  29
        case SGAc:
            return "SGA";
            // TOPT-APRX  Approx Message Size Negotiation     4  Prop  Ele     ...
        case 4:
            return "APPROX MESSAGE SIZE NEGOTIATION";
            // TOPT-STAT  Status                              5  Std   Rec     859  30
        case 5:
            return "STATUS";
            // TOPT-TIM   Timing Mark                         6  Std   Rec     860  31
        case 6:
            return "TIMING MARK";
            // TOPT-REM   Remote Controlled Trans and Echo    7  Prop  Ele     726
        case 7:
            return "OUTPUT LINE WIDTH";
            // TOPT-OLW   Output Line Width                   8  Prop  Ele     ...
        case 8:
            return "OUTPUT LINE WIDTH";
            // TOPT-OPS   Output Page Size                    9  Prop  Ele     ...
        case 9:
            return "OUTPUT PAGE SIZE";
            // TOPT-OCRD  Output Carriage-Return Disposition 10  Hist  Ele     652    *
        case 10:
            return "OUTPUT CR DISPOSITION";
            // TOPT-OHT   Output Horizontal Tabstops         11  Hist  Ele     653    *
            // TOPT-OHTD  Output Horizontal Tab Disposition  12  Hist  Ele     654    *
            // TOPT-OFD   Output Formfeed Disposition        13  Hist  Ele     655    *
            // TOPT-OVT   Output Vertical Tabstops           14  Hist  Ele     656    *
            // TOPT-OVTD  Output Vertical Tab Disposition    15  Hist  Ele     657    *
            // TOPT-OLD   Output Linefeed Disposition        16  Hist  Ele     658    *
            // TOPT-EXT   Extended ASCII                     17  Prop  Ele     698
        case 17:
            return "EXTENDED ASCII";
            // TOPT-LOGO  Logout                             18  Prop  Ele     727
        case 18:
            return "LOGOUT";
            // TOPT-BYTE  Byte Macro                         19  Prop  Ele     735
        case 19:
            return "BYTE MACRO";
            // TOPT-DATA  Data Entry Terminal                20  Prop  Ele    1043
        case 20:
            return "DATA ENTRY TERMINAL";
            // TOPT-SUP   SUPDUP                             21  Prop  Ele     736
        case 21:
            return "SUPDUP";
            // TOPT-SUPO  SUPDUP Output                      22  Prop  Ele     749
        case 22:
            return "SUPDUP OUTPUT";
            // TOPT-SNDL  Send Location                      23  Prop  Ele     779
        case 23:
            return "SEND LOCATION";
            // TOPT-TERM  Terminal Type                      24  Prop  Ele    1091
        case TTc:
            return "TERMINAL TYPE";
            // TOPT-EOR   End of Record                      25  Prop  Ele     885
        case EORc:
            return "END OF RECORD";
            // TOPT-TACACS  TACACS User Identification       26  Prop  Ele     927
            // TOPT-OM    Output Marking                     27  Prop  Ele     933
            // TOPT-TLN   Terminal Location Number           28  Prop  Ele     946
            // TOPT-3270  Telnet 3270 Regime                 29  Prop  Ele    1041
            // TOPT-X.3   X.3 PAD                            30  Prop  Ele    1053
            // TOPT-NAWS  Negotiate About Window Size        31  Prop  Ele    1073
        case NAWSc:
            return "NAWS";
            // TOPT-TS    Terminal Speed                     32  Prop  Ele    1079
        case 32:
            return "TS";
            // TOPT-RFC   Remote Flow Control                33  Prop  Ele    1372
            // TOPT-LINE  Linemode                           34  Draft Ele    1184
        case LINEMODEc:
            return "LINEMODE";
            // TOPT-XDL   X Display Location                 35  Prop  Ele    1096
            // TOPT-ENVIR Telnet Environment Option          36  Hist  Not    1408
        case 36:
            return "ENVIR-OLD";
            // TOPT-AUTH  Telnet Authentication Option       37  Exp   Ele    1416
        case 37:
            return "AUTH";
            // TOPT-ENVIR Telnet Environment Option          39  Prop  Ele    1572
        case 39:
            return "ENVIR";
            // TOPT-TN3270E TN3270 Enhancements              40  Draft Ele    2355    *
            // TOPT-AUTH  Telnet XAUTH                       41  Exp
            // TOPT-CHARSET Telnet CHARSET                   42  Exp          2066
        case 42:
            return "CHARSET";
            // TOPR-RSP   Telnet Remote Serial Port          43  Exp
            // TOPT-COMPORT Telnet Com Port Control          44  Exp          2217
            // TOPT-SLE   Telnet Suppress Local Echo         45  Exp                  *
            // TOPT-STARTTLS Telnet Start TLS                46  Exp                  *
        case START_TLSc:
            return "START_TLS";
            // TOPT-KERMIT   Telnet KERMIT                   47  Exp                  *
            // TOPT-SEND-URL Send-URL                        48  Exp                  *
        case COMPRESS2c:
            return "COMPRESSv2";
        case MSPc: // Mud Sound Protocol.
            return "MSP";
        case MXPc: // Mud eXtension Protocol.
            return "MXP";
        case ZMPc: // Mud eXtension Protocol.
            return "ZMP";
        case MPLEXc:
            return "MPLEX";
            // TOPT-EXTOP Extended-Options-List             255  Std   Rec     861  32
        case -128:
            return "EXTOP";
        default:
            {
                static char buff[4];
                sprintf(buff, "%d", (unsigned)c);
                return buff;
            }
    }
}

static const char *
get_telnet_state(telnet_option_state tos)
{
    switch(tos) {
        case tos_YES:
            return "YES";
        case tos_NO:
            return "NO";
        case tos_WANTYES_EMPTY:
            return "WANTYES_EMPTY";
        case tos_WANTNO_EMPTY:
            return "WANTNO_EMPTY";
        case tos_WANTYES_OPPOSITE:
            return "WANTYES_OPPOSITE";
        case tos_WANTNO_OPPOSITE:
            return "WANTNO_OPPOSITE";
        default:
            return "UNKNOWN-ERROR!";
    }
}

static void telnet_enable_him_option(int clinr, char c);

static void
telnet_turned_on_him_option(int clinr, char c)
{
    switch(c) {
        case TTc:
            server_write(clinr, IAC SB TT "\001" IAC SE, 6, 0);
            mputs(clinr, "SENT IAC SB TERMINAL TYPE SEND IAC SE");
    }
}

static bool
telnet_turn_on_us_option(int clinr, char c)
{
    switch(c) {
        case SGAc:
            telnet_enable_him_option(clinr, TMc);
            /* fputs("CHAR BY CHAR\n", CONNECT_LOG); */
            return true;
        case ECHOc:
            return true;
        case EORc:
            clients[clinr].mode |= SM_EORECORDS;
            server_write(clinr, IAC ENDOFRECORD, 2, SW_DO_FLUSH);
            mputs(clinr, "SENT IAC ENDOFRECORD");
            /* don't resend the prompt, since it is the
             * clients job to just show the already received
             * one. */
            return true;
        case CHARSETc:
            // server_write(clinr, IAC SB CHARSET "\001;ISO_8859-1;US-ASCII" IAC SE, 5+21, SW_DO_FLUSH);
            // simple_write(clinr, "SENT IAC SB CHARSET REQUEST \";ISO_8859-1;US-ASCII\" IAC SE\r\n");
            return true;
#if HAVE_ZLIB
        case COMPRESS2c:
            if(clients[clinr].stream) {
                simple_write(clinr, "ERROR: RCVD WILL COMPRESS2 while having SM_START_COMRESS/stream\r\n");
            } else {
                /* Got: IAC WILL COMPRESS2 */
                simple_write(clinr, "preparing to turn on compress\r\n");
            }
            return true;
#endif
        case ZMPc:
            send_zmp(clinr, "zmp.ident", "ZMP-test-server", "1.0", "A server to test clients' ability to speak telnet and ZMP", 0);
            return true;
    }

    return false;
}

static void
telnet_turned_off_us_option(int clinr, char c)
{
    switch(c) {
#if HAVE_ZLIB
        case COMPRESS2c:
            // XXX
            break;
#endif
        case ECHOc:
            break;
        case SGAc:
            break;
        case EORc:
            clients[clinr].mode &= ~SM_EORECORDS;
            break;
    }
}

static void
send_telnet_will(int clinr, char c, int flags)
{
    char buff[3];
    buff[0] = IACc;
    buff[1] = WILLc;
    buff[2] = c;
    server_write(clinr, buff, 3, flags);
    sprintf(debug_buffer, "SENT IAC WILL %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(clients[clinr].tos_us[(unsigned)c]));
    mputs(clinr, debug_buffer);
}

static void
send_telnet_wont(int clinr, char c, int flags)
{
    char buff[3];
    buff[0] = IACc;
    buff[1] = WONTc;
    buff[2] = c;
    server_write(clinr, buff, 3, flags);
    sprintf(debug_buffer, "SENT IAC WONT %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(clients[clinr].tos_us[(unsigned)c]));
    mputs(clinr, debug_buffer);
}

static void
send_telnet_do(int clinr, char c, int flags)
{
    char buff[3];
    buff[0] = IACc;
    buff[1] = DOc;
    buff[2] = c;
    server_write(clinr, buff, 3, flags);
    sprintf(debug_buffer, "SENT IAC DO %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(clients[clinr].tos_him[(unsigned)c]));
    mputs(clinr, debug_buffer);
}

static void
send_telnet_dont(int clinr, char c, int flags)
{
    char buff[3];
    buff[0] = IACc;
    buff[1] = DONTc;
    buff[2] = c;
    server_write(clinr, buff, 3, flags);
    sprintf(debug_buffer, "SENT IAC DONT %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(clients[clinr].tos_him[(unsigned)c]));
    mputs(clinr, debug_buffer);
}

static void
telnet_enable_him_option(int clinr, char c)
{
    telnet_option_state *him_q = &(clients[clinr].tos_him[(unsigned)c]);

    switch(*him_q) {
        case tos_NO:
            // NO            him=WANTYES, send DO.
            *him_q = tos_WANTYES_EMPTY;
            send_telnet_do(clinr, c, SW_DO_FLUSH);
            break;
        case tos_YES:
            // YES           Error: Already enabled.
            sprintf(debug_buffer,
                    "ERROR: trying to enable telnet option %s that is already enabled: %s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*him_q));
            simple_write(clinr, debug_buffer);
            break;

        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY If we are queueing requests, himq=OPPOSITE;
            //               otherwise, Error: Cannot initiate new request
            //               in the middle of negotiation.
            *him_q = tos_WANTNO_OPPOSITE;
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE Error: Already queued an enable request.
            sprintf(debug_buffer,
                    "ERROR: trying to enable telnet option %s that is already queued: %s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*him_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY Error: Already negotiating for enable.
            sprintf(debug_buffer,
                    "ERROR: trying to enable telnet option %s that is already under negotiation: %s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*him_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE himq=EMPTY.
            *him_q = tos_WANTYES_EMPTY;
            break;
        default:
            sprintf(debug_buffer,
                    "ERROR: Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *him_q);
            simple_write(clinr, debug_buffer);
    }
}

static void
telnet_enable_us_option(int clinr, char c)
{
    telnet_option_state *us_q = &(clients[clinr].tos_us[(unsigned)c]);

    switch(*us_q) {
        case tos_NO:
            // NO            us=WANTYES, send WILL.
            *us_q = tos_WANTYES_EMPTY;
            send_telnet_will(clinr, c, SW_DO_FLUSH);
            break;
        case tos_YES:
            // YES           Error: Already enabled.
            sprintf(debug_buffer,
                    "error: trying to enable telnet option %s that is already enabled: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;

        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY If we are queueing requests, himq=OPPOSITE;
            //               otherwise, Error: Cannot initiate new request
            //               in the middle of negotiation.
            *us_q = tos_WANTNO_OPPOSITE;
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE Error: Already queued an enable request.
            sprintf(debug_buffer,
                    "ERROR: trying to enable telnet option %s that is already queued: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY Error: Already negotiating for enable.
            sprintf(debug_buffer,
                    "ERROR: trying to enable telnet option %s that is already under negotiation: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE himq=EMPTY.
            *us_q = tos_WANTYES_EMPTY;
            break;
        default:
            sprintf(debug_buffer,
                    "ERROR: Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *us_q);
            simple_write(clinr, debug_buffer);
    }
}

static void
telnet_disable_us_option(int clinr, char c)
{
    telnet_option_state *us_q = &(clients[clinr].tos_us[(unsigned)c]);

    switch(*us_q) {
        case tos_NO:
            //    NO            Error: Already disabled.
            sprintf(debug_buffer,
                    "ERROR: trying to disable telnet option %s that is already disabled: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_YES:
            //    YES           us=WANTNO, send WONT.
            *us_q = tos_WANTNO_EMPTY;
            send_telnet_wont(clinr, c, SW_DO_FLUSH);
            break;
        case tos_WANTNO_EMPTY:
            //    WANTNO  EMPTY Error: Already negotiating for disable.
            sprintf(debug_buffer,
                    "ERROR: trying to disable telnet option %s that is already being negotiated: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;
        case tos_WANTNO_OPPOSITE:
            //         OPPOSITE himq=EMPTY.
            *us_q = tos_WANTNO_EMPTY;
            break;
        case tos_WANTYES_EMPTY:
            //    WANTYES EMPTY If we are queueing requests, himq=OPPOSITE;
            //                  otherwise, Error: Cannot initiate new request
            //                  in the middle of negotiation.
            *us_q = tos_WANTYES_OPPOSITE;
            break;
        case tos_WANTYES_OPPOSITE:
            //         OPPOSITE Error: Already queued a disable request.
            sprintf(debug_buffer,
                    "error: trying to disable telnet option %s that is already queued: us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            break;
        default:
            sprintf(debug_buffer,
                    "Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *us_q);
            simple_write(clinr, debug_buffer);
    }
}

void
process_zmp(int clinr, char *buff, int len)
{
    char *s = buff;
    if(len < 2) {
        simple_write(clinr, "ERROR: Too short ZMP command received\r\n");
        return;
    }
    if(buff[len-1]) {
        simple_write(clinr, "ERROR: Received a ZMP command that did not end with a NUL character\r\n");
        return;
    }
    while(s < (buff+len)) {
        if(*s && !isalnum(*s) && *s != '.' && *s != '-') {
            sprintf(debug_buffer, "ERROR: Illegal ZMP command containing the character '%c' received.\r\n", *s);
            simple_write(clinr, debug_buffer);
            return;
        }
        if(!*s++) break;
    }
    simple_write(clinr, "Received ZMP Command: ");
    simple_write(clinr, buff);

    if(!strcmp(buff, "zmp.ping")) {
        time_t t; time(&t);
        char buffer[30];

        simple_write(clinr, "\r\n");

        strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", gmtime(&t));
        send_zmp(clinr, "zmp.time", buffer, 0);
        return;
#if 0
    }else if(!strcmp(buff, "zpm.check")) {
        char buffer[100];
        buffer[99] = 0;
        simple_write(clinr, "\r\n");

        strncpy(buffer, buff, sizeof(buffer)-1);
        /* always answer with support... */
        send_zmp(clinr, "zmp.support", buffer, 0);
        return;
    }else if(!strcmp(buff, "zpm.input")) {
        simple_write(clinr, "\r\n");
        process_line(clinr, s);
        return;
#endif
    }
    len -= s-buff;
    buff = s;
    while(len > 0) {
        simple_write(clinr, " \"");
        simple_write(clinr, s);
        while(*s && s < buff+len) s++;
        s++;
        simple_write(clinr, "\"");
        len -= s-buff;
        buff = s;
    }
    simple_write(clinr, "\r\n");
}

static int
process_telnet_do_option(int clinr, char c)
{
    telnet_option_state *us_q = &(clients[clinr].tos_us[(unsigned)c]);

    sprintf(debug_buffer, "RCVD IAC DO %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(*us_q));
    mputs(clinr, debug_buffer);

    switch(*us_q) {
        case tos_NO:
            // NO            If we agree that we should enable, us=YES, send WILL; otherwise, send WONT.
            if(telnet_turn_on_us_option(clinr, c)) {
                *us_q = tos_YES;
                send_telnet_will(clinr, c, SW_DO_FLUSH);
            } else send_telnet_wont(clinr, c, SW_DO_FLUSH);
            break;
        case tos_YES:
            // YES           Ignore.
            break;
        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY Error: WONT answered by DO. us=NO.
            sprintf(debug_buffer,
                    "ERROR: WONT answered by DO for telnet option %s. us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            *us_q = tos_NO;
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY us=YES.
            *us_q = tos_YES;
            telnet_turn_on_us_option(clinr, c);
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE Error: WONT answered by DO. us=YES*, usq=EMPTY.
            sprintf(debug_buffer,
                    "ERROR: WONT answered by DO for telnet option %s. us_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*us_q));
            simple_write(clinr, debug_buffer);
            *us_q = tos_YES;
            telnet_turn_on_us_option(clinr, c);
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE him=WANTNO, himq=EMPTY, send WONT.
            *us_q = tos_WANTNO_EMPTY;
            send_telnet_wont(clinr, c, SW_DO_FLUSH);
            break;
        default:
            sprintf(debug_buffer,
                    "ERROR: Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *us_q);
            simple_write(clinr, debug_buffer);
    }
    return 0;
}

static int
process_telnet_dont_option(int clinr, char c)
{
    telnet_option_state *us_q = &(clients[clinr].tos_us[(unsigned)c]);
    sprintf(debug_buffer, "RCVD IAC DONT %s (us_q=%s)",
            get_telnet_option(c),
            get_telnet_state(*us_q));
    mputs(clinr, debug_buffer);

    switch(*us_q) {
        case tos_NO:
            // NO            Ignore.
            break;
        case tos_YES:
            // YES           us=NO, send WONT.
            *us_q = tos_NO;
            telnet_turned_off_us_option(clinr, c);
            send_telnet_wont(clinr, c, SW_DO_FLUSH);
            break;
        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY us=NO.
            *us_q = tos_NO;
            telnet_turned_off_us_option(clinr, c);
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE us=WANTYES, usq=NONE, send WILL.
            *us_q = tos_WANTYES_EMPTY;
            send_telnet_will(clinr, c, SW_DO_FLUSH);
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY us=NO.*
            *us_q = tos_NO;
            telnet_turned_off_us_option(clinr, c);
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE us=NO, usq=NONE.**
            *us_q = tos_NO;
            telnet_turned_off_us_option(clinr, c);
            break;
        default:
            sprintf(debug_buffer,
                    "Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *us_q);
            simple_write(clinr, debug_buffer);
    }
    return 0;
}

static int
process_telnet_will_option(int clinr, char c)
{
    telnet_option_state *him_q = &(clients[clinr].tos_him[(unsigned)c]);
    sprintf(debug_buffer, "RCVD IAC WILL %s (him_q=%s)",
            get_telnet_option(c),
            get_telnet_state(*him_q));
    mputs(clinr, debug_buffer);

    switch(*him_q) {
        case tos_NO:
            // NO            If we agree that he should enable, him=YES, send DO; otherwise, send DONT.
            switch(c) {
                case NAWSc: /* NAWS */
                    // Yes, please.
                    *him_q = tos_YES;
                    send_telnet_do(clinr, c, SW_DO_FLUSH);
                    break;
                case TTc:	/* TERMINAL TYPE */
                    /* IAC SB TERMINAL TYPE SEND IAC SE */
                    *him_q = tos_YES;
                    send_telnet_do(clinr, c, SW_DO_FLUSH);
                    telnet_turned_on_him_option(clinr, c);
                    break;
                default:
                    send_telnet_dont(clinr, c, SW_DO_FLUSH);
            }
            break;
        case tos_YES:
            // YES           Ignore.
            break;
        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY Error: DONT answered by WILL. him=NO.
            sprintf(debug_buffer,
                    "ERROR: DONT answered by WILL for telnet option %s. him_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*him_q));
            simple_write(clinr, debug_buffer);
            *him_q = tos_NO;
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY him=YES.
            *him_q = tos_YES;
            telnet_turned_on_him_option(clinr, c);
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE Error: DONT answered by WILL. him=YES*, himq=EMPTY.
            sprintf(debug_buffer,
                    "ERROR: DONT answered by WILL for telnet option %s. him_q=%s\r\n", 
                    get_telnet_option(c),
                    get_telnet_state(*him_q));
            simple_write(clinr, debug_buffer);
            *him_q = tos_YES;
            telnet_turned_on_him_option(clinr, c);
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE him=WANTNO, himq=EMPTY, send DONT.
            *him_q = tos_WANTNO_EMPTY;
            send_telnet_dont(clinr, c, SW_DO_FLUSH);
            break;
        default:
            sprintf(debug_buffer,
                    "ERROR: Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *him_q);
            simple_write(clinr, debug_buffer);
    }

    return 0;
}

static int
process_telnet_wont_option(int clinr, char c)
{
    telnet_option_state *him_q = &(clients[clinr].tos_him[(unsigned)c]);

    sprintf(debug_buffer, "RCVD IAC WONT %s (him_q=%s)",
            get_telnet_option(c),
            get_telnet_state(*him_q));
    mputs(clinr, debug_buffer);

    switch(*him_q) {
        case tos_NO:
            // NO            Ignore.
            break;
        case tos_YES:
            // YES           him=NO, send DONT.
            *him_q = tos_NO;
            send_telnet_dont(clinr, c, SW_DO_FLUSH);
            break;
        case tos_WANTNO_EMPTY:
            // WANTNO  EMPTY him=NO.
            *him_q = tos_NO;
            break;
        case tos_WANTNO_OPPOSITE:
            //      OPPOSITE him=WANTYES, himq=NONE, send DO.
            *him_q = tos_WANTYES_EMPTY;
            send_telnet_do(clinr, c, SW_DO_FLUSH);
            break;
        case tos_WANTYES_EMPTY:
            // WANTYES EMPTY him=NO.*
            *him_q = tos_NO;
            break;
        case tos_WANTYES_OPPOSITE:
            //      OPPOSITE him=NO, himq=NONE.**
            *him_q = tos_NO;
            break;
        default:
            sprintf(debug_buffer,
                    "Incorrect telnet option state for option %s: %d\r\n", 
                    get_telnet_option(c),
                    *him_q);
            simple_write(clinr, debug_buffer);
    }
    return 0;
}

static void
send_debug_data(int clinr, char *buff, int len)
{
    while(len > 0) {
        sprintf(debug_buffer, "%02x ", *buff++);
        simple_write(clinr, debug_buffer);
        len--;
    }
}

static bool
is_equal(const char *buff, int len, const char *str)
{
    int y = strlen(str);
    if(len != y) return false;
    return !strncasecmp(buff, str, len);
}

static bool
is_ok_charset(const char *buff, int len)
{
    if(is_equal(buff, len, "UTF-8")) return true;

    // ASCII and its various aliases:
    if(is_equal(buff, len, "ANSI_X3.4-1968")) return true;
    if(is_equal(buff, len, "iso-ir-6")) return true;
    if(is_equal(buff, len, "ANSI_X3.4-1986")) return true;
    if(is_equal(buff, len, "IS_646.irv:1991")) return true;
    if(is_equal(buff, len, "ASCII")) return true;
    if(is_equal(buff, len, "ISO646-US")) return true;
    if(is_equal(buff, len, "US-ASCII")) return true;
    if(is_equal(buff, len, "us")) return true;
    if(is_equal(buff, len, "IBM367")) return true;
    if(is_equal(buff, len, "cp367")) return true;
    if(is_equal(buff, len, "csASCII")) return true;

    // ISO-8859-1 & its aliases:
    if(is_equal(buff, len, "ISO_8859-1:1987")) return true;
    if(is_equal(buff, len, "iso-ir-100")) return true;
    if(is_equal(buff, len, "ISO_8859-1")) return true;
    if(is_equal(buff, len, "ISO-8859-1")) return true;
    if(is_equal(buff, len, "latin1")) return true;
    if(is_equal(buff, len, "l1")) return true;
    if(is_equal(buff, len, "IBM819")) return true;
    if(is_equal(buff, len, "CP819")) return true;
    if(is_equal(buff, len, "csISOLatin1")) return true;

    return false;
}

static int
process_telnet_sb_option(int clinr)
{
    char *buff = &clients[clinr].holdbuff[clients[clinr].curr];
    int len = clients[clinr].telnet_position - clients[clinr].curr;
    int pos = 0;
    int i;
    if(should_send_debug(clinr)) {
	sprintf(debug_buffer, "RCVD IAC SB %s ", get_telnet_option(buff[0]));
	simple_write(clinr, debug_buffer);
	for(i = 1; i < len; i++) {
	    sprintf(debug_buffer, "%02X ", buff[i]);
	    simple_write(clinr, debug_buffer);
	}
	sprintf(debug_buffer, "IAC SE\r\n");
	simple_write(clinr, debug_buffer);
    }
    switch (buff[0]) {
        case CHARSETc:	/* CHARSET */
            if(len - pos < 2) {
                sprintf(debug_buffer, "ERROR: The CHARSET SB option was incomplete.\r\n");
                simple_write(clinr, debug_buffer);
                break;
            }
            switch(buff[++pos]) {
                case 1: /* Request */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET REQUEST ");
			int x = pos;
			while(++x <= len) {
			    /* XXX support for sending the version string */
			    server_write(clinr, buff+x, 1, 0);
			}
			simple_write(clinr, "\r\n");
		    }
		    pos++;
		    if(!strncmp("TTABLE", buff+pos, 6)) pos += 7; // Skip TTABLE and a VERSION byte.
		    char sep = buff[pos];
		    int start = ++pos;
		    bool is_ok = false;
		    while(pos < len) {
			if(buff[pos] == sep) {
			    if(is_ok_charset(buff+start, pos-start)) {
				is_ok = true;
				break;
			    }
			    start = ++pos;
			}
			pos++;
		    }
		    if(!is_ok && is_ok_charset(buff+start, pos-start)) {
			is_ok = true;
		    }
		    if(is_ok) {
			server_write(clinr, IAC SB CHARSET "\002", 4, 0);
			server_write(clinr, buff + start, pos-start, 0);
		        server_write(clinr, IAC SE, 2, SW_DO_FLUSH);
			if(should_send_debug(clinr)) {
			    simple_write(clinr, "SENT IAC SB CHARSET ACCEPT \"");
			    server_write(clinr, buff + start, pos-start, 0);
			    simple_write(clinr, "\" IAC SE\r\n");
			}
		    } else {
			server_write(clinr, IAC SB CHARSET "\003" IAC SE, 6, SW_DO_FLUSH);
			mputs(clinr, "SENT IAC SB CHARSET REJECT IAC SE");
		    }
                    break;
                case 2: /* ACCEPTED */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET ACCEPTED ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    break;
                case 3: /* REJECTED */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET REJECTED ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    break;
                case 4: /* TTABLE-IS */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET TTABLE-IS ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    server_write(clinr, IAC SB CHARSET "\005" IAC SE, 6, SW_DO_FLUSH);
                    mputs(clinr, "SENT IAC SB CHARSET TTABLE-REJECTED IAC SE");
                    break;
                case 5: /* TTABLE-REJECTED */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET TTABLE-REJECTED ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    break;
                case 6: /* TTABLE-ACK */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET TTABLE-ACK ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    break;
                case 7: /* TTABLE-NAK */
		    if(should_send_debug(clinr)) {
			simple_write(clinr, "RCVD IAC SB CHARSET TTABLE-NAK ");
			send_debug_data(clinr, buff + pos, len-pos);
			simple_write(clinr, "IAC SE\r\n");
		    }
                    break;
                default:
                    sprintf(debug_buffer, "ERROR(?): Received unknown CHARSET SB Code: %02x\r\n", buff[pos]);
                    simple_write(clinr, debug_buffer);
            }
            break;
        case TTc:	/* TERMINAL-TYPE */
            if(pos == len) {
                sprintf(debug_buffer, "ERROR: An incomplete SB option?\r\n");
                simple_write(clinr, debug_buffer);
                break;
            }
            if(buff[++pos] != 0)
                break;
	    sprintf(debug_buffer, "TT: \"");
	    simple_write(clinr, debug_buffer);
	    pos++;
	    while(pos < len) {
		sprintf(debug_buffer, "%c", (int)(buff[pos++]));
		simple_write(clinr, debug_buffer);
	    }
	    simple_write(clinr, "\"\r\n");

            break;
        case NAWSc:	/* NAWS */
            if(len < 4) {
                sprintf(debug_buffer, "ERROR: Too few arguments to SB NAWS\r\n");
                simple_write(clinr, debug_buffer);
                break;
            }

            int x, y, x_size, y_size;

            x = 255 & (unsigned)buff[++pos];
            if(x == 255) {
                x = 255&(unsigned)buff[++pos];
            }
            y = 255 & (unsigned)buff[++pos];
            if(y == 255) {
                y = 255 & (unsigned)buff[++pos];
            }
            x_size = x * 256 + y;

            x = 255 & (unsigned)buff[++pos];
            if(x == 255) {
                x = 255&(unsigned)buff[++pos];
            }
            y = 255 & (unsigned)buff[++pos];
            if(y == 255) {
                y = 255 & (unsigned)buff[++pos];
            }
            y_size = x * 256 + y;
            sprintf(debug_buffer, "Terminal size: %d %d",
                    x_size,
                    y_size);
            mputs(clinr, debug_buffer);
            break;
        case ZMPc:
            process_zmp(clinr, buff+1, len-1);
            break;
        default:
            sprintf(debug_buffer,
                    "Unknown telnet SB option: %02X",
                    buff[0]);
            mputs(clinr, debug_buffer);
    }
    return 0;
}

static bool
should_echo(int clinr) {
    return (clients[clinr].tos_us[ECHOc] == tos_YES) &&
           !(clients[clinr].mode & SM_INVISIBLE);
}

static bool
store_char(int clinr, unsigned char c)
{
    // ignore control chars, they should have been
    // parsed already if we wanted them.
    if(c < ' ') return true;
    if(c >= (unsigned char) '\200' &&
            c <= (unsigned char) '\237') return true;

    int line_left = LINELEN - clients[clinr].curr;
    if(line_left <= 0) return false; // no more room.

    clients[clinr].holdbuff[clients[clinr].curr++] = c;
    if(should_echo(clinr)) {
        server_write(clinr, (const char*)&c, 1, SW_DO_FLUSH);
    }
    return true;
}

static int
process_linefeed(int clinr)
{
    if((clients[clinr].tos_us[ECHOc] == tos_YES) ||
       (clients[clinr].mode & (SM_INVISIBLE))) {
        server_write(clinr, "\r\n", 2, 0);
    }
    clients[clinr].holdbuff[clients[clinr].curr] = 0;
    clients[clinr].curr = 0;
    return 1;
    /* There might be more in the buffert but that
       has to wait until this line is read */
}

static int
process_normal_char(int clinr, char c)
{
    unsigned int line_left = LINELEN - clients[clinr].curr;

    switch(clients[clinr].c_state) {
        case crlf_cr:
            if(c == '\0') { /* CR NUL */
                clients[clinr].c_state = crlf_normal;
                return 0;
            } else if(c == '\n') {
                /* CR LF -> real newline */
                clients[clinr].c_state = crlf_normal;
                return 0;
            } else {
                clients[clinr].c_state = crlf_normal;
                simple_write(clinr, "ERROR: Got CR without NUL nor LF\r\n");
                return process_normal_char(clinr, c);
            }
            break;
        case crlf_lf:
            if(c == '\0') {
                // LF NUL -> treat as newline */
                clients[clinr].c_state = crlf_normal;
                simple_write(clinr, "WARN: Got LF NUL\r\n");
                return 0;
            } else if(c == '\r') {
                // LF CR, unusual, but allowed...
                clients[clinr].c_state = crlf_normal;
                simple_write(clinr, "ERROR: Got LF CR\r\n");
                return 0;
            } else {
                clients[clinr].c_state = crlf_normal;
                simple_write(clinr, "WARN: Got LF without CR\r\n");
                return process_normal_char(clinr, c);
            }
            break;
        default:
            switch (c) {
                case '\000':    /* NUL */
                    break;		/* Ignore zeros */
                case '\012':	/* ^J LF */
                    clients[clinr].c_state = crlf_lf;
                    return process_linefeed(clinr);
                case '\015':	/* ^M CR */
                    clients[clinr].c_state = crlf_cr;
                    return process_linefeed(clinr);
                case '\022':	/* ^R Refresh */
                    if(should_echo(clinr)) {
                        char buff[LINELEN + 2];
                        buff[0] = '\r';
                        buff[1] = '\n';
                        strncpy(&buff[2], clients[clinr].holdbuff,
                                LINELEN - line_left);
                        server_write(clinr, buff, LINELEN - line_left + 2, SW_DO_FLUSH);
                    }
                    break;
                case '\025':	/* ^U Erase line */
                    if(should_echo(clinr)) {
                        char buff[3 * LINELEN + 1];
                        unsigned int j = 0;
                        while(j < (3 * (LINELEN - line_left))) {
                            buff[j++] = '\010';
                            buff[j++] = ' ';
                            buff[j++] = '\010';
                        }
                        server_write(clinr, buff, j, SW_DO_FLUSH);
                    }
                    clients[clinr].curr = 0;
                    break;
                case '\027':	/* ^W Erase last word */
                    {
                        char buff[3 * LINELEN];
                        unsigned int j = 0;
                        while((line_left < LINELEN) &&
                                (clients[clinr].holdbuff[LINELEN - line_left - 1] == ' ')) {
                            buff[j++] = '\010';
                            buff[j++] = ' ';
                            buff[j++] = '\010';
                            line_left++;
                        }
                        while((line_left < LINELEN) &&
                                (clients[clinr].holdbuff[LINELEN - line_left - 1] != ' ')) {
                            buff[j++] = '\010';
                            buff[j++] = ' ';
                            buff[j++] = '\010';
                            line_left++;
                        }
                        if(should_echo(clinr)) {
                            if(j > 0)
                                server_write(clinr, buff, j, SW_DO_FLUSH);
                        }
                        clients[clinr].curr = LINELEN - line_left;
                    }
                    break;
                case '\010':	/* Backspace and delete */
                case '\177':
                    line_left += 1;
                    if(line_left > LINELEN)
                        line_left = LINELEN;
                    else if(should_echo(clinr)) {
                        char *buff = "\010 \010";
                        server_write(clinr, buff, 3, SW_DO_FLUSH);
                    }
                    clients[clinr].curr = LINELEN - line_left;
                    break;
                default:
                    store_char(clinr, c);
            }
            return 0;
    }
}

static int
process_char(int clinr, char c)
{
    switch(clients[clinr].t_state) {
        case ts_iac:
            switch(c) {
                case IACc:
                    store_char(clinr, IACc);
                    clients[clinr].t_state = ts_normal;
                    break;
                case WILLc:
                    clients[clinr].t_state = ts_will;
                    break;
                case WONTc:
                    clients[clinr].t_state = ts_wont;
                    break;
                case DOc:
                    clients[clinr].t_state = ts_do;
                    break;
                case DONTc:
                    clients[clinr].t_state = ts_dont;
                    break;
                case SBc:
                    clients[clinr].t_state = ts_sb;
                    clients[clinr].telnet_position = clients[clinr].curr;
                    break;
                case '\371':	/* GA -> Go ahead */
                    mputs(clinr, "RCVD: IAC GA");
                    clients[clinr].t_state = ts_normal;
                    break;
                case '\370':	/* EL -> Erase line */
                    mputs(clinr, "RCVD: IAC EL");
                    clients[clinr].t_state = ts_normal;
                    return process_normal_char(clinr, '\025');
                    break;
                case '\367':	/* EC -> Erase character */
                    mputs(clinr, "RCVD: IAC EC");
                    clients[clinr].t_state = ts_normal;
                    return process_normal_char(clinr, '\010');
                    break;
                case '\366':	/* AYT -> Are you there? */
                    mputs(clinr, "RCVD: IAC AYT");
                    server_write(clinr, "<I AM HERE>\r\n", 13, SW_DO_FLUSH);
                    clients[clinr].t_state = ts_normal;
                    break;
                case '\365':	/* AO -> Abort output */
                    mputs(clinr, "RCVD: IAC AO");
                    clients[clinr].t_state = ts_normal;
                    // should flush the output buffer, but that
                    // is hard with telnet options and
                    // ansi sequences.
                    server_write(clinr, IAC DM, 2, SW_DO_FLUSH);
                    mputs(clinr, "SENT: IAC DM");
                    break;
                case '\364':	/* IP -> interrupt process--permanently */
                    /* ARGH. this text is lost...  */
                    mputs(clinr, "RCVD: IAC IP");
                    clients[clinr].t_state = ts_normal;
                    break;
                case '\363':	/* BREAK */
                    mputs(clinr, "RCVD: IAC BREAK");
                    clients[clinr].t_state = ts_normal;
                    break;
                case '\361':	/* NOP */
                    mputs(clinr, "RCVD: IAC NOP");
                    clients[clinr].t_state = ts_normal;
                    /* Yep, I'll do nothing */
                    break;
                case '\356':	/* ABORT */
                    mputs(clinr, "RCVD: IAC ABORT");
                    clients[clinr].t_state = ts_normal;
                    /* No way. We don't abort for you... */
                    break;
                case '\355':	/* SUSPEND */
                    mputs(clinr, "RCVD: IAC SUSPEND");
                    clients[clinr].t_state = ts_normal;
                    /* Yeah, sure... */
                    break;
                default:
                    sprintf(debug_buffer, "ERROR(?): RCVD: IAC followed by 0x%02x\r\n", c);
                    simple_write(clinr, debug_buffer);
                    clients[clinr].t_state = ts_normal;
                    break;
            }
            break;
        case ts_will:
            clients[clinr].t_state = ts_normal;
            return process_telnet_will_option(clinr, c);
        case ts_wont:
            clients[clinr].t_state = ts_normal;
            return process_telnet_wont_option(clinr, c);
        case ts_do:
            clients[clinr].t_state = ts_normal;
            return process_telnet_do_option(clinr, c);
        case ts_dont:
            clients[clinr].t_state = ts_normal;
            return process_telnet_dont_option(clinr, c);
        case ts_sbiac:
            if(c == IACc) {
                clients[clinr].t_state = ts_sb;
                clients[clinr].holdbuff[clients[clinr].telnet_position++] = c;
            } else if(c == SEc) {
                // Done.
                clients[clinr].t_state = ts_normal;
                return process_telnet_sb_option(clinr);
            } else {
                // error.
                clients[clinr].t_state = ts_normal;
                return 0;
            }
            break;
        case ts_sb:
            if(c == IACc) {
                clients[clinr].t_state = ts_sbiac;
                break;
            }
            clients[clinr].holdbuff[clients[clinr].telnet_position++] = c;
            break;
        case ts_normal:
            if(c == IACc) {
                clients[clinr].t_state = ts_iac;
                break;
            }
        default:
            return process_normal_char(clinr, c);
    }
    return 0;
}

static int
process_input(int clinr)
{
    char in_buff[LINELEN + 16];	/* A bit extra for prompts and some control chars */
    unsigned int line_left = LINELEN - clients[clinr].curr;
    int received = recv(clinr, in_buff, line_left, MSG_PEEK);
    int i;
    if(received <= 0) {
        return -1;
    }
    for(i = 0; i < received; i++) {
        if (process_char(clinr, in_buff[i])) {
            recv(clinr, in_buff, i+1, 0); /* Eat what we have read */
            return 1;
        }
    }
    recv(clinr, in_buff, i, 0);	/* Eat what we have read */
    return 0;
}

void
server_invisible(int clinr)
{
    clients[clinr].mode |= SM_INVISIBLE;
    if(!(clients[clinr].tos_us[ECHOc] == tos_YES)) {
        telnet_enable_us_option(clinr, ECHOc);
    }
}

void
server_visible(int clinr)
{
    clients[clinr].mode &= ~SM_INVISIBLE;
    if(clients[clinr].tos_us[ECHOc] == tos_YES) {
        telnet_disable_us_option(clinr, ECHOc);
    }
}

int
server_poll(long sec, long usec)
{
    int i, j, k;
    struct timeval timer;
    read_fd_mask = select_fd_mask;
    write_fd_mask = select_write_fd_mask;
#ifdef __SVR4
    exc_fd_mask = select_fd_mask;
#endif				/* __SVR4 */
    timer.tv_sec = sec;
    timer.tv_usec = usec;
#ifdef __SVR4
    i = select(high_fd, &read_fd_mask, &write_fd_mask, &exc_fd_mask,
	       (sec || usec) ? &timer : (struct timeval *) NULL);
#else
    i = select(high_fd, &read_fd_mask, &write_fd_mask, NULL,
	       (sec || usec) ? &timer : (struct timeval *) NULL);
#endif				/* __SVR4 */
    if(i <= 0)
	return i;
    for(j = 0; j < high_fd; j++)
	if(j != daemon_fd) {
#ifdef __SVR4
	    if(FD_ISSET(j, &exc_fd_mask)) {
		char buff[1024];
		k = recv(j, buff, sizeof(buff), MSG_OOB);
		if(k < 0) {
		    FD_SET(j, &read_fd_mask);
		    FD_CLR(j, &exc_fd_mask);
		} else {
		    continue;
		}
	    }
#endif				/* __SVR4 */

            if(FD_ISSET(j, &read_fd_mask)) {
                k = process_input(j);
                if(!k) {	/* If the client is not done with the line ... */
                    FD_CLR(j, &read_fd_mask);	/* ...remove it from the waiting */
                    i--;
                } else if(k < 0) {
                    clients[j].mode |= SM_QUITING;
                }
            }
            if(FD_ISSET(j, &write_fd_mask)) {
                /* An users write had failed */
                int retval;
                if((retval = send(j, clients[j].writebuff->text,
                                clients[j].writelen >
                                BLOCK_SIZE ? BLOCK_SIZE : clients[j].
                                writelen, 0)) > 0) {
                    output_queue *next = clients[j].writebuff->next;
                    free(clients[j].writebuff);

                    if(next)
                        clients[j].writelen -= BLOCK_SIZE;
                    else {
                        clients[j].writelen = 0;
                        FD_CLR(j, &select_write_fd_mask);
                    }
                    clients[j].writebuff = next;
                } else {
                    clients[j].mode |= SM_QUITING;
                }
            }
	    if(clients[j].mode & SM_QUITING)
		FD_SET(j, &read_fd_mask);
	}
    return i;
}

int
server_pending(void)
{
    return FD_ISSET(daemon_fd, &read_fd_mask);
}

int
server_accept(void)
{
    struct sockaddr_storage from;
    socklen_t len = sizeof(from);
    int i = accept(daemon_fd, (struct sockaddr *)&from, &len);

    if(i < 0) {
	perror("server_accept");
	return -1;
    }

    FD_CLR(daemon_fd, &read_fd_mask);

    if(i >= MAX_FD) {
	close(i);	/* A message or a hook should perhapps be put here */
	return -1;
    }

    memset(&clients[i], 0, sizeof(clients[i]));

    memcpy(&clients[i].address, &from, sizeof(clients[i].address));
    clients[i].address_len = len;

    if(i >= high_fd) high_fd = i + 1;
    clients[i].curr = 0;
    clients[i].mode = 0;
    FD_SET(i, &select_fd_mask);
#if HAVE_ZLIB
    clients[i].stream = NULL;
#endif
    clients[i].writebuff = NULL;
    clients[i].writelen = 0;
    clients[i].x_size = clients[i].y_size = 0;

    clients[i].is_connected = true;

    telnet_enable_us_option(i, CHARSETc);
    telnet_enable_us_option(i, EORc);
    telnet_enable_him_option(i, NAWSc);
    // telnet_enable_us_option(i, SGAc);
    telnet_enable_him_option(i, TTc);
    telnet_enable_us_option(i, ZMPc);
#if HAVE_ZLIB
    telnet_enable_us_option(i, COMPRESS2c);
#endif

    return i;
}

int
server_ready(int clientnr)
/* Is the clientnr client ready with a line ? */
{
    return FD_ISSET(clientnr, &read_fd_mask);
}

int
server_close(int clientnr)
/* Close and dealloc everything that has to do with the <clientnr> client. */
{
    clients[clientnr].is_connected = false;
    clients[clientnr].mode = 0;
    FD_CLR(clientnr, &select_write_fd_mask);
    FD_CLR(clientnr, &select_fd_mask);
    FD_CLR(clientnr, &read_fd_mask);
    FD_CLR(clientnr, &write_fd_mask);
    while(!FD_ISSET(high_fd - 1, &select_fd_mask))
	--high_fd;
    while(clients[clientnr].writebuff) {
        output_queue *next = clients[clientnr].writebuff->next;
        free(clients[clientnr].writebuff);
        clients[clientnr].writebuff = next;
    }
    key_value *curr = clients[clientnr].variables;
    while(curr) {
	key_value *next = curr->next;
	free(curr->key);
	free(curr->value);
	free(curr);
	curr = next;
    }
    shutdown(clientnr, SHUT_RDWR);
    return close(clientnr);
}

int
server_prompt(int clientnr, const char *prompt, int size)
{
    if(should_echo(clientnr)) {
	char buff[LINELEN + 80 + 3];	/* 80 = max length of the prompt */
	strncpy(buff, prompt, size);
	strncpy(&buff[size], clients[clientnr].holdbuff,
		clients[clientnr].curr);
	server_write(clientnr, buff, size + clients[clientnr].curr, SW_DO_FLUSH);
    } else {
	char buff[LINELEN + 80 + 3];
	strncpy(buff, prompt, size);
	if(clients[clientnr].mode & SM_EORECORDS) {
	    buff[size++] = IACc;
	    buff[size++] = '\357';	/* IAC END-OF-RECORD */
	}
	server_write(clientnr, buff, size, SW_DO_FLUSH);
    }
    return 0;
}

/* It is assumed that telnet characters are already properly
 * escaped when server_write is called.
 *
 * flags can be:
 *    SW_DONT_COMPRESS - don't compress, even if the client supports
 *                       compression. Only used internally.
 *    SW_DO_FLUSH - Make sure compression buffers are sent.
 */
int
server_write(int clientnr, const char *mesg, int mesglen, int flags)
{
    int retval = 0;

#if HAVE_ZLIB

    if(!(flags & SW_DONT_COMPRESS) && clients[clientnr].stream) {
        z_stream *stream = clients[clientnr].stream;

        stream->next_in = (Bytef*)mesg;
        stream->avail_in = mesglen;

        while((flags & (SW_FINISH|SW_DO_FLUSH)) ||
               stream->avail_in ||
               stream->avail_out != COMP_BUFF_LEN) {

            if(!(flags & (SW_DO_FLUSH|SW_FINISH)) &&
               !stream->avail_in &&
               stream->avail_out == COMP_BUFF_LEN)
                return retval;

            int z_flag = Z_NO_FLUSH;
            if(flags & SW_FINISH) {
                z_flag = Z_FINISH;
            } else if(flags & SW_DO_FLUSH) {
                z_flag = Z_SYNC_FLUSH;
            }
            switch(deflate(stream, z_flag)) {
                case Z_BUF_ERROR:
                    /* sprintf(debug_buffer, "Got Z_BUF_ERROR %d:%d %s\r\n", stream->avail_in, COMP_BUFF_LEN - stream->avail_out, stream->msg);
                    simple_write(clientnr, debug_buffer); */
                    return retval;
                case Z_STREAM_END:
                     clients[clientnr].stream = NULL;
                case Z_OK:
                    if(COMP_BUFF_LEN != stream->avail_out) {
                        retval = server_write(clientnr,
                                              (char*)clients[clientnr].comp_buffer,
                                              COMP_BUFF_LEN - stream->avail_out,
                                              SW_DONT_COMPRESS);
                        stream->next_out = clients[clientnr].comp_buffer;
                        stream->avail_out = COMP_BUFF_LEN;
                    }
                    if(!clients[clientnr].stream) {
                        sprintf(debug_buffer, "CompStatistics: in: %ld, out %ld %.1f%%\r\n", 
                                    stream->total_in,
                                    stream->total_out,
                                    100.0*(float)stream->total_out /
                                                 stream->total_in);
                        deflateEnd(stream);
                        free(stream);
                        free(clients[clientnr].comp_buffer);
                        clients[clientnr].comp_buffer = NULL;
                        simple_write(clientnr, debug_buffer);
                        return retval;
                    }
                    break;
                case Z_STREAM_ERROR:
                default:
                    fprintf(stderr, "Something went bad with compression: %s\n", stream->msg);
                    deflateEnd(stream);
                    free(stream);
                    free(clients[clientnr].comp_buffer);
                    clients[clientnr].comp_buffer = NULL;
                    clients[clientnr].stream = NULL;
                    return retval;
            }
        }
        return retval;
    }
#endif

    if(mesglen == 0) return 0; // SW_DO_FLUSH for example.

    if(clients[clientnr].writelen) {
	output_queue *last = (output_queue *) & clients[clientnr].writebuff;
	output_queue *noq;
	int startpos = clients[clientnr].writelen % BLOCK_SIZE;
	int size;

	clients[clientnr].writelen += mesglen;
	if(clients[clientnr].writelen > DROP_AT) {
	    /* The client has WAY too much queued text... Loose it! */
	    clients[clientnr].mode |= SM_QUITING;
	    FD_SET(clientnr, &select_write_fd_mask);
	    return -1;
	}
	while(last->next)
	    last = last->next;
	size = mesglen;
	if(size > (BLOCK_SIZE - startpos))
	    size = BLOCK_SIZE - startpos;
	memcpy(&last->text[startpos], mesg, size);
	mesglen -= size;
	mesg += size;
	while(mesglen > 0) {
	    noq = (output_queue*)malloc(sizeof(output_queue));
	    noq->next = NULL;
	    size = mesglen > BLOCK_SIZE ? BLOCK_SIZE : mesglen;
	    memcpy(noq->text, mesg, size);
	    mesg += size;
	    mesglen -= size;
	    last->next = noq;
	    last = noq;
	}
	return 1;
    } else {
        int send_flags = 0;
#ifdef MSG_MORE
        // if(!(flags & SW_DO_FLUSH)) send_flags |= MSG_MORE;
#endif
	do {
	    retval = send(clientnr, mesg, mesglen > 2 ? 2 : mesglen, send_flags);
            if(retval == -1 && errno == ENOTSOCK) {
                retval = write(clientnr, mesg, mesglen);
            }
	    if(retval != mesglen) {

		{
		    int n = 0;
		    socklen_t n_len = sizeof(n);
		    if(0 == getsockopt(clientnr, SOL_SOCKET, SO_SNDBUF, &n, &n_len)) {
                        /*
			sprintf(debug_buffer, "Failed to write %d (%d) SO_SNDBUF %d %d\r\n",
				mesglen, retval, clientnr, n);
                        simple_write(clientnr, debug_buffer);
                        */
		    }
		}

		if(retval > 0) {
		    mesglen -= retval;
		    mesg += retval;
		} else {
		    /* Store it in the queue */
		    output_queue *last =
			(output_queue *) & clients[clientnr].writebuff;

		    FD_SET(clientnr, &select_write_fd_mask);

		    while(mesglen > 0) {
			output_queue *noq = (output_queue*)malloc(sizeof(output_queue));
			int size = mesglen > BLOCK_SIZE ? BLOCK_SIZE : mesglen;

			noq->next = NULL;
			memcpy(noq->text, mesg, size);
			clients[clientnr].writelen += size;
			mesg += size;
			mesglen -= size;
			last->next = noq;
			last = noq;
		    }
		}
	    } else {
#if HAVE_ZLIB
                /* Turn on compression */
                if((clients[clientnr].tos_us[COMPRESS2c] == tos_YES) &&
                   !clients[clientnr].stream &&
                   !(flags & SW_DONT_COMPRESS)) {
                    z_stream *stream = calloc(1, sizeof(z_stream));
                    stream->zalloc = Z_NULL;
                    stream->zfree = Z_NULL;
                    stream->opaque = Z_NULL;
                    clients[clientnr].comp_buffer = calloc(sizeof(Bytef), COMP_BUFF_LEN);
                    stream->next_out = clients[clientnr].comp_buffer;
                    stream->avail_out = COMP_BUFF_LEN;
                    if(deflateInit(stream, 6) != Z_OK) {
                        fprintf(stderr, "Failed to initialise z_stream\n");
                        free(stream);
                        break;
                    }
                    /* IAC SB COMPRESS2 IAC SE */
                    server_write(clientnr, IAC SB COMPRESS2 IAC SE, 5, SW_DONT_COMPRESS);

                    /* Start compression... */
                    clients[clientnr].stream = stream;

                    simple_write(clientnr, "SENT IAC SB COMPRESS2 IAC SE\r\n");
                } else if((clients[clientnr].tos_us[COMPRESS2c] == tos_NO) &&
                          clients[clientnr].stream) {
                    server_write(clientnr, "Turning off COMPRESS2\r\n", 23, SW_FINISH|SW_DO_FLUSH);
                }
#endif
		break;		/* We've sent it, we're done! */
            }
	} while(retval > 0);
    }
    return retval;
}

char *
server_read(int clientnr)
{
    if(clients[clientnr].mode & SM_QUITING)
	return NULL;		/* Client has disconected. */
    else
	return clients[clientnr].holdbuff;
}

void
server_shutdown(void)
{
    int i;
    for(i = 0; i < high_fd; i++)
        if(FD_ISSET(i, &select_fd_mask)) {
            if(i == daemon_fd)
                close(i);
            else
                server_close(i);
        }
}

void
send_zmp(int fd, ...)
{
    va_list ap;
    va_list aq;
    char *s;

    va_start(ap, fd);
    va_copy(aq, ap);

    server_write(fd, IAC SB ZMP, 3, 0);
    while((s = va_arg(aq, char *))) {
        char *x = s;
        while(*x) {
            if(*x == IACc) {
                server_write(fd, IAC, 1, 0);
            }
            server_write(fd, x++, 1, 0);
        }
        server_write(fd, "", 1, 0);
    }
    va_end(aq);
    server_write(fd, IAC SE, 2, 0);

    simple_write(fd, "SENT IAC SB ZMP ");
    while((s = va_arg(ap, char *))) {
        simple_write(fd, "\"");
        simple_write(fd, s);
        simple_write(fd, "\" ");
    }
    va_end(ap);
    simple_write(fd, "IAC SE\r\n");
}

static void
handle_zmp(int fd, char *line)
{
    /* split the args */
    char *args[MAX_ZMP_ARGS];
    int n_args = 1;
    int i, len;
    args[0] = line;
    if(!*args) {
        simple_write(fd, "USAGE: zmp cmd [<arg>|\"<arg>\"]*\r\n");
    }

    /* split the string into commands: */
    do {
        if(*line == '"') {
            args[n_args-1]++;
            line++;
            /* XXX have some way of excaping " characters... */
            while(*line && *line != '"') line++;
            if(*line != '"') {
                simple_write(fd, "ERROR: Unterminated ZMP argument\r\n");
                return;
            }
            *line++ = 0;
        } else {
            while(*line && *line != ' ') line++;
            if(*line) *line++ = 0;
        }
        while(*line == ' ') line++;
        if(*line) {
            args[n_args++] = line;
        }
    } while(*line && n_args < MAX_ZMP_ARGS);

    /* How large will the string be? */
    len = 5; /* IAC SB ZMP IAC SE */
    for(i = 0; i < n_args; i++) {
        char *s = args[i];
        while(*s) {
            if(*s == IACc) len++;
            len++;
            s++;
        }
        len++; /* For the NUL */
    }

    /* Allocate, build the string, send and free: */
    line = (char*)malloc(len);
    if(line) {
        char *s = line;
        *s++ = IACc;
        *s++ = SBc;
        *s++ = ZMPc;
        simple_write(fd, "Sending: IAC SB ZMP ");
        for(i = 0; i < n_args; i++) {
            char *x = args[i];
            simple_write(fd, "\"");
            simple_write(fd, x);
            simple_write(fd, "\" ");
            while(*x) {
                if(*x == IACc) *s++ = IACc;
                *s++ = *x++;
            }
            *s++ = 0;
        }
        *s++ = IACc;
        *s++ = SEc;
        simple_write(fd, "IAC SE\r\n");
        server_write(fd, line, s-line, 0);
        free(line);
    } else {
        simple_write(fd, "ERROR: failed to allocate memory for the ZMP command\r\n");
    }
}

static void
colour_show(int fd)
{
    int b;
    const char cols[] = "nrgybmcwNRGYBMCW";
    simple_write(fd, "These are the colours:\r\n  n  r  g  y  b  m  c  w  "
            "N  R  G  Y  B  M  C  W\r\n");
    for(b = 0; b < 8; b++) {
        int bold;
        char tmp[3] = "  ";
        *tmp = cols[b];
        simple_write(fd, tmp);
        for(bold = 0; bold < 2; bold++) {
            int f;
            for(f = 0; f < 8; f++) {
                if(bold) {
                    sprintf(debug_buffer, "\e[1;3%d;4%dm%c%c \033[0m", f, b, cols[f+8], cols[b]);
                } else {
                    sprintf(debug_buffer, "\e[0;3%d;4%dm%c%c \033[0m", f, b, cols[f], cols[b]);
                }
                simple_write(fd, debug_buffer);
            }
        }
        simple_write(fd, "\r\n");
    }
}

static void
colour_show256(int fd)
{
    int c, i, j, r, g, b;
    const char cols[] = "nrgybmcwNRGYBMCW";
    const char rgb[] = "012345";

    simple_write(fd, "Basic colours:  ");
    for(i = 0; i < 8; i++) {
        sprintf(debug_buffer, "\033[3%dm%c", i, cols[i]);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, " ");
    for(i = 0; i < 8; i++) {
        sprintf(debug_buffer, "\033[4%dm%c", i, cols[i]);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, "\033[0m\r\nBright colours: \033[1m");
    for(i = 0; i < 8; i++) {
        sprintf(debug_buffer, "\033[3%dm%c", i, cols[i+8]);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, " ");

    for(i = 0; i < 8; i++) {
        sprintf(debug_buffer, "\033[4%dm%c", i, cols[i]);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, "\033[0m\r\n\r\n6x6x6 colour cubes:\r\n  R");

    for(i = 0; i < 6; i++)
        simple_write(fd, rgb);
    simple_write(fd, " ");

    for(i = 0; i < 6; i++)
        simple_write(fd, rgb);
    
    simple_write(fd, "\r\n  G");

    for(c = 0; c < 2; c++) {
        if(c == 1) simple_write(fd, " ");
        for(i = 0; i < 6; i++)
            for(j = 0; j < 6; j++) {
                *debug_buffer = i + '0';
                debug_buffer[1] = 0;
                simple_write(fd, debug_buffer);
            }
    }
    simple_write(fd, "\r\n");
    for(b = 0; b < 6; b++) {
        sprintf(debug_buffer, "B%d ", b);
        simple_write(fd, debug_buffer);
        for(g = 0; g < 6; g++) {
            for(r = 0; r < 6; r++) {
                sprintf(debug_buffer, "\033[38;5;%dmX", 16+r*36+g*6+b);
                simple_write(fd, debug_buffer);
            }
        }
        simple_write(fd, "\033[0m ");
        for(g = 0; g < 6; g++) {
            for(r = 0; r < 6; r++) {
                sprintf(debug_buffer, "\033[48;5;%dmX", 16+r*36+g*6+b);
                simple_write(fd, debug_buffer);
            }
        }
        simple_write(fd, "\033[0m\r\n");
    }

    simple_write(fd, "\r\nGreyscales (0-23): ");

    for(i = 0; i < 24; i++) {
        sprintf(debug_buffer, "\033[38;5;%dmX", 16+6*6*6+i);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, " ");
    for(i = 0; i < 24; i++) {
        sprintf(debug_buffer, "\033[48;5;%dmX", 16+6*6*6+i);
        simple_write(fd, debug_buffer);
    }
    simple_write(fd, "\033[0m\r\n");
}

static void
send_data(int fd, char *line)
{
    char *s;
    if(!*line) {
        simple_write(fd, "USAGE: senddata <hex byte> <hex byte>*\r\nExample: senddata 41 42 43  -- sends ABC\r\n");
        return;
    }
    while((s = strtok(line, " "))) {
        int x;
        line = 0;
        if(sscanf(s, "%x", &x) != 1 || x > 255 || x < 0) {
            simple_write(fd, "\r\nERROR: Unknown byte.\r\n");
            return;
        } else {
            char c = (char)x;
            server_write(fd, &c, 1, 0);
        }
    }
    simple_write(fd, "\r\n");
}

static void
set_var(int fd, const char *key, const char *value)
{
    key_value *curr = clients[fd].variables;
    while(curr) {
	if(!strcmp(curr->key, key)) {
	    // Update.
	    free(curr->value);
	    curr->value = strdup(value);
	    return;
	}
	curr = curr->next;
    }
    // New value.
    curr = malloc(sizeof(key_value));
    curr->next = clients[fd].variables;
    curr->key = strdup(key);
    curr->value = strdup(value);
    clients[fd].variables = curr;
}

static void
remove_var(int fd, const char *key)
{
    key_value *last = clients[fd].variables;
    if(!last) return;
    if(!strcmp(last->key, key)) {
	clients[fd].variables = last->next;
	free(last->key);
	free(last->value);
	free(last);
	return;
    }
    while(last->next) {
	key_value *curr = last->next;
	if(!strcmp(curr->key, key)) {
	    last->next = curr->next;
	    free(curr->key);
	    free(curr->value);
	    free(curr);
	    return;
	}
	last = last->next;
    }
}

static void
handle_set(int fd, char *args)
{
    if(!*args) {
	key_value *curr = clients[fd].variables;
	if(!curr) {
	    simple_write(fd, "No variables are set.\r\n"
		    "Use \"set var value\" to set the \"var\" variable to \"value\".\r\n"
		    "Use \"set var\" to unset the \"var\" variable.\r\n"
		    "Known variables are:\r\n"
		    "  nodebug - if set to any value, stops telnet options from being displayed.\r\n"
		    );
	} else {
	    while(curr) {
		sprintf(debug_buffer, "%s=%s\r\n", curr->key, curr->value);
		simple_write(fd, debug_buffer);
		curr = curr->next;
	    }
	}
    } else {
	char *key = args;
	char *value = NULL;
	while(*args++) {
	    if(*args == ' ') {
		*args = 0;
		value = args+1;
		break;
	    }
	}
	if(value && !*value) value = NULL;

	if(value) {
	    set_var(fd, key, value);
	} else {
	    remove_var(fd, key);
	}
    }
}

static void
test_cc(int fd, const char *args)
{
    switch(atoi(args)) {
        case 1:
            simple_write(fd,
                    "\e[3H\e[2J>\e[HX\e[;5HV\e[1;1H "
                    "\r\n"
                    "\e[3;5H"
                    "* - should be pointed to by V and > (line 3, column 5)\r\n"
                    "\r\nThe screen should only contain this text, "
                    "the message above, \"V\", \">\"\r\n"
                    "and \"* -\" plus the new prompt. "
                    "The V should be on the first line,\r\n"
                    "the > in the first column and this is the only X.\r\n");
            break;
        case 2:
            simple_write(fd,
                         "\e[H\e[2J"
                         "123456789>\r\n"
                         "2   YY\r\n"
                         "3  YabY\r\n"
                         "4  YcdY\r\n"
                         "5   YY\r\n"
                         "V\r\n"
                         "\e[H"
                         "\e[B\e[2B\e[C\e[4CDX"
                         "\e[2A\e[3D  \e[D\e[2D\e[B AX "
                         "\e[E"
			 "\e[3C C"
                         "\e[F\e[2F\e[5C\e[2BB"
                         "\e[6G\e[2B \e[5G "
                         "\e[4;7H "
                         "\r\n\r\n\r\n\r\n"
                         "The screen should now show \"AB\" "
                         "and below it \"CD\".\r\n"
                         "A should be shown in the third row, "
                         "fifth column.\r\n");
            break;
        case 3:
            simple_write(fd,
                         "\e[H\e[2J"
                         "XXXXXXXXXXXXXXXXXXXX\r\n"
                         "XXXXXXXXX#XXXXXXXXXX\r\n"
                         "XXXXXXX#####XXXXXXXX\r\n"
                         "XXXXXXXXXXXXXXXXXXXX\r\n"
                         "XXXXXXXXX#XXXXXXXXXX\r\n"
                         "XXXXXXXXXXXXXXXXXXXX\r\n"
                         "\e[2;9H\e[1J"
                         "\e[11G\e[K"
                         "\e[3;7H\e[1K"
                         "\e[13G\e[0K"
                         "\e[5;11H\e[J\e[2D\e[1K"
                         "\e[A\e[2K"
                         "\r\n\r\n\r\n\r\n"
                         "This is the only \"X\" that should be visible. "
                         "Line one, four and six should\r\n"
                         "be empty. If line four were to be removed, a 3x5 character\r\n"
                         "large plus-sign would be visible, "
                         "made of 7 characters.\r\n"
                    );
            break;
        case 4:
            simple_write(fd,
                         "\r\n"
                         "\e(0"
                         "lqwqk    " "\r\n"
                         "xAxBx    " "\r\n"
                         "tqnqu    " "\r\n"
                         "xCxDx    " "\r\n"
                         "mqvqj    " "\r\n"
                         "y z a ` f g\e(B\r\n\r\n"
                         "A, B, C and D should be nicely framed with lines, then a line of symbols;\r\n"
                         "<=, >=, checkers, a diamond, a degree-sign and finally +-\r\n"
                         );
            break;
        case 5:
            simple_write(fd,
                         "\r\n"
                         "\e[2J\e[H\r\n"
                         "\e[33;41;1m"
                         "Storing the cursor here.\e7XXXXXX\r\n"
                         "\e[0;32;40mChanging cursor colour.\r\n"
                         "\e8XXXXXXXXXXXXX\r\n"
                         "\e8 After restoration of cursor.\e[m\r\n\r\n\r\n"
                         "The first row is empty, the second row should read:\r\n"
                         "Storing the cursor here. After restoration of cursor.\r\n"
                         "The colour of the second row is bright yellow on a red background,\r\n"
                         "the third row is written in dark green above a black background.\r\n"
                         "This is the only X.\r\n"
                    );
            break;
        case 6:
            simple_write(fd,
                    "\e[2J\e[H"
                    "1\r\n" "X\r\n" "X\r\n" "X\r\n" "5\r\n"
                    "\e[;3HXXXACF"
                    "\e[3G" // CHA - cursor character absolute; pos becomes 1,3
		    "\e[P"  // DCH - delete character; "XXACF"
		    "\e[2P" // DCH - delete character; "ACF"
                    "\e[4G" // CHA - cursor pos becomes 1,4
		    "\e[@"  // ICH - insert space...; "A CF"
		    "\e[2C" // CUF - Cursor Forward, pos becomes 1,6
		    "\e[2@" // ICH - insert space...; "A C  F"
                    "\e[4G" // CHA - cursor pos becomes 1,4
		    "B"     //                        "ABC  F"
		    "\e[6G" // CHA - cursor pos comes 1,6
		    "DE"    //                        "ABCDEF"
                    "\e[2H"
		    "\e[M"  // DL
		    "\e[2M"
		    "\e[L"  // IL
		    "\e[2L" // IL
                    "\e[2H"
		    "2\r\n3\r\n4"
                    "\e[5;3H"
		    "a\e[2b"     // REP
		    "b\e[b"      // REP
		    "c\e[1b\e[b" // REP
		    "d"
                    "\r\n\r\n\r\n"
                    "The first row should be: \"1 ABCDEF\".\r\n"
                    "There should be a column with 1..5 "
                    "and this is the only X.\r\n"
                    "The fifth row should be \"5 aaabbccd\" or \"5 aaabbcccd\"\r\n"
                    );
            break;
        case 7:
            simple_write(fd,
                    "\e]0;Window and icon name\007"
                    "\e]1;Icon name\007"
                    "\e]2;Window title\007"
                    "The window title should now be \"Window title\"\r\n"
                    "The icon name should now be \"Icon name\"\r\n");
            break;
        case 8:
            simple_write(fd,
                    "\e[2J" // ED2 - Clear entire screen.
		    "\e[6;0H" // CUP - Move to (col,row) - (1,6).
		    "6"
		    "\e[;4r" // DECSTBM - Sets Top and Bottom Margins to 1 and 4. Moves cursor to (1,1).
                    "X\r\n" "X\r\n" "X\r\n" "X\r\n"
                    "2\r\n" "X\r\n" "X"
                    "\e[3;5r" // DECSTBM - Sets Top and Bottom Margins to 3,5. Moves cursor to (1,1).
		    "X\r\n"
                    "\r\n"
		    "X\r\n"
		    "X\r\n"
		    "3\r\n"
		    "4\r\n"
                    "\e[r1" // DECSTBM - Sets Top and Bottom Margsins to 1 and number of lines. Moves cursor to (1,1).
		    "\e[5;1H" // CUP - Move to (1,5).
		    "5"
		    "\r\n" "\r\n" "\r\n"
                    "A column with 1..6 is shown, starting at the first row. "
                    "This is the only X.\r\n"
                   );
	    simple_write(fd, "\e[10H");
            break;
        case 9:
            simple_write(fd, "\ec\r\n");
            break;
        case 10:
	    simple_write(fd,
                    "\e[2J" // ED2 - Clear entire screen.
		    "\e[5;1H" // CUP - Move to (col,row) - (1,5).
		    "6"
		    "\e[1;1H" // CUP - Move to (col,row) - (1,1).
		    "2"
		    "\eM" // Reverse index.
		    "\010" // BACKSPACE
		    "1"
                    "\e[3;5r" // DECSTBM - Sets Top and Bottom Margins to 3,5. Moves cursor to (1,1).
                    "\r\n\r\n" // Move cursor down two steps.
		    "X"
		    "\eM" // Reverse index.
		    "\010" // BACKSPACE
		    "5"
		    "\eM" // Reverse index.
		    "\010" // BACKSPACE
		    "4"
		    "\eM" // Reverse index.
		    "\010" // BACKSPACE
		    "3"
		    "\e[H" // HOME - Moves the cursor to (1,1).
		    "\eM" // Reverse index.
		    "This is the last line of the screen."
                    "\e[r1" // DECSTBM - Sets Top and Bottom Margsins to 1 and number of lines. Moves cursor to (1,1).
		    "\e[8;1H"
		    "The screen should show 1..6 from the upper left corner and down.\r\n"
		    "The last line should have a text about it. This is the only X.\r\n");
	    break;
	case 11:
	    simple_write(fd,
		"This should show a single tile:\r\n"
		"\e[2;3z" // Output to window 3 == MAP.
		);
		int i;
		for(i = 0; i < 80; i++) {
			char buff[80];
			snprintf(buff, 79,
					"\e[0;%uz" // Start of glyph 1
					"X" // This should not be shown.
					"\e[1z" // End of glyph
					, i);
			simple_write(fd, buff);
		}
	    simple_write(fd,
		"\e[3z" // End of data.
		"\r\nThis is the only X.\r\n"
		    );
	    break;

        default:
            simple_write(fd,
      "VT100/102 & xterm tests:\r\n"
      "testcc 1  - clears the screen, absolute cursor movement tests.\r\n"
      "testcc 2  - clears the screen, relative cursor movement tests.\r\n"
      "testcc 3  - erase tests.\r\n"
      "testcc 4  - \"DEC\" graphics.\r\n"
      "testcc 5  - storing/restoring the cursor.\r\n"
      "testcc 6  - text insertion tests.\r\n"
      "testcc 7  - xterm icon & window title tests.\r\n"
      "testcc 8  - scroll region tests.\r\n"
      "testcc 9  - reset the terminal.\r\n"
      "testcc 10 - test Reverse Index.\r\n"
      "testcc 11 - NetHack's vt_tileset patch's output.\r\n"
            );
    }
#if 0
    simple_write(fd, "\e[23;1H\e[2K\e7\e[1;1H\e[r\e[2J\e[1;20r\e8");
    simple_write(fd, "\e7\e[20;1HHi there...\r\n");
    sleep(5);
    simple_write(fd, "\e8");
    sleep(5);
    simple_write(fd, "\e[r\r\n");
#endif
}

static void
test_text(int fd, char *args)
{
    switch(atoi(args)) {
	case 1:
	    simple_write(fd, "First line\r\n");
	    server_prompt(fd, "> ", 2);
	    sleep(1);
	    server_write(fd, "\r", 2, 0);
	    simple_write(fd, "Second line\r\nThere should no longer be a > character between the first and second line.\r\n");
	    break;
	case 2:
	    simple_write(fd,
		    "\e%@" // Select default, iso-8859-1, character set.
		    "(iso-8859-1 charset): A single y character, with \" above it: \377\377\r\n"
		    "Word wrapping test. The next line contains non-breaking spaces:\r\n"
		    "In\240this\240long\240line\240of\240text,\240the\240only\240place\240where space\240is\240used\240is\240before\240the\240first\240space\240word.\r\n"
		    );
	    break;
	case 3:
	    simple_write(fd,
		    "\e%G" // Select UTF-8 character set.
		    "(utf-8 charset): A single a character with \" above it: \xC3\xA4 and again: a\xCC\x88\r\n"
		    "Word wrapping test. The next line contains non-breaking spaces:\r\n"
		    "In\302\240this\302\240long\302\240line\302\240of\302\240text,\302\240the\302\240only\302\240place\302\240where space\302\240is\302\240used\302\240is\302\240before\302\240the\302\240first\302\240space\302\240word.\r\n"
		    );
	    break;
	case 4:
	    simple_write(fd, "This test assumes the screen is 80 characters wide.\r\n"
		    "This 80 character line should not be wrapped. The line should properly end here.\r\n"
		    "This 81 character line should be wrapped. Xyzzy hocus pocus plugh shazam alakazam\r\n"
		    "This 81 character line should also be wrapped. Abracadabra plugh plover alakazam.\r\n"
		    "This 81 character line should be wrapped too.  Klaatu barada nikto!  Hocus-pocus.\r\n"
		    "This 81 character line should be wrapped as well. Klaatu barada nikto hocus-pocus\r\n"
		    );
	    break;
	case 5:
	    simple_write(fd,
		    "Backspace is destructive NOT!\010\010\010\010\r\n"
		    "\r\n"
		    "\0103\r\n"
		    "\r\n"
		    "\r\n"
		    "\"3\" should be in the first column and there should be a blank\r\n"
		    "line between the \"Backspace is...\" text and the line with \"3\".\r\n"
		    "The first line should end with \"NOT!\"\r\n"
		    );
	    simple_write(fd, "Backspace is destructive NOT!\010\010\010\010\r\n");
	    break;
	default:
	    simple_write(fd,
		    "Test processing tests:\r\n"
		    "testtext 1 - tests carriage return handling.\r\n"
		    "testtext 2 - tests ISO-8859-1 text handling.\r\n"
		    "testtext 3 - tests UTF-8 text handling.\r\n"
		    "testtext 4 - more word wrapping tests\r\n"
		    "testtext 5 - Backspace testing.\r\n"
		    );
    }
}


static int
get_port(struct sockaddr_storage *addr)
{
    switch(addr->ss_family) {
	case AF_INET:
	    return ntohs(((struct sockaddr_in*)addr)->sin_port);
#ifdef AF_INET6
	case AF_INET6:
	    return ntohs(((struct sockaddr_in6*)addr)->sin6_port);
#endif
	default:
	    return 0;
    }
}

static void
set_port(struct sockaddr_storage *addr, int port)
{
    port = htons(port);
    switch(addr->ss_family) {
	case AF_INET:
	    ((struct sockaddr_in*)addr)->sin_port = port;
	    break;
#ifdef AF_INET6
 	case AF_INET6:
		((struct sockaddr_in6*)addr)->sin6_port = port;
	    break;
#endif
    }

}

static void
ident(int fd)
{
    struct sockaddr_storage addr;
    socklen_t alen;
    char buff[256];
    int our_port;
#ifdef PF_INET6
    int s = socket((clients[fd].address.ss_family == AF_INET) ? PF_INET : PF_INET6, SOCK_STREAM, 0);
#else
    int s = socket(PF_INET, SOCK_STREAM, 0);
#endif

    if(s == -1) {
	perror("socket");
	return;
    }

    if(getsockname(fd, (struct sockaddr*)&addr, &alen) == -1) {
	perror("getsockname");
	close(s);
	simple_write(fd, "Failed to get the sockets address?\r\n");
	return;
    }

    our_port = get_port(&addr);
    set_port(&addr, 0);

    if(-1 == bind(s, (struct sockaddr*)&addr, alen)) {
	perror("bind");
	close(s);
	simple_write(fd, "Failed to bind to the server's IP number?\r\n");
	return;
    }

    addr = clients[fd].address;
    set_port(&addr, 113); // ident

    if(-1 == connect(s, (struct sockaddr *)&addr, clients[fd].address_len)) {
	perror("connect");
	close(s);
	simple_write(fd, "Failed to connect to the ident port\r\n");
	return;
    }

    snprintf(buff, sizeof(buff)-1,
	    "%d, %d\r\n",
	     get_port(&clients[fd].address),
	     our_port);

    write(s, buff, strlen(buff));
    int len = read(s, buff, 255);
    if(len > 0) {
	buff[len] = 0;
	// assume we got everything...
	simple_write(fd, "Result: ");
	simple_write(fd, buff);
	simple_write(fd, "\r\n");
    } else {
	if(len == -1) perror("connect");
	simple_write(fd, "Failed to get any data from the peer's ident server\r\n");
    }
    close(s);

    return;
}

static void
process_line(int fd, char *line)
{
    char *s = line + strlen(line);
    char *args = "";
    simple_write(fd, "\r\n");
    while(*line == ' ') line++;
    while(s > line && s[-1] == ' ') s--;
    if(*s) *s = 0;
    s = line;
    while(*s && *s != ' ') s++;
    if(*s == ' ') {
        *s++ = 0;
        while(*s == ' ') s++;
        args = s;
    }
    if(!strcmp("?", line) ||
            !strcasecmp("help", line)) {
        simple_write(fd,
                "Commands: \r\n"
		"cat [<maxsize>] - sends the test.txt file (up to byte <maxsize>)\r\n"
                "colourshow - show the 16 ansi colours.\r\n"
                "colourshow256 - show the 256 xterm colours.\r\n"
                "eall <text> - sends text to all connected clients (without a prompt afterwards).\r\n"
                "echo - turn server echo on/off.\r\n"
		"ident - try to look up the user id via IDENT, RFC1413\r\n"
		"promptall <text> - send text to all connected clients without newline\r\n"
                "quit - leave\r\n"
                "sendasis <string> - send the string back on a new line.\r\n"
                "senddata <hex byte>* - send the bytes back.\r\n"
		"set <variable> <value> - set a variable.\r\n"
                "startmsp - start telnet msp option negotiation.\r\n"
                "startmxp - start telnet mxp option negotiation.\r\n"
                "stopmccp - finish the zlib stream.\r\n"
                "telnet - Hex codes for some telnet constants.\r\n"
                "testansi - Various ANSI colour tests.\r\n"
                "testcc - Various control code sequence tests.\r\n"
                "testtext - Various text tests.\r\n"
                "tt - Ask the client for the next terminal type.\r\n"
                "zmp <cmd> [<args>|\"<arg>\"]* - send a ZMP command.\r\n"
                );
    } else if(!strcasecmp("cat", line)) {
	int max = atoi(args);
	if(!max) max = 1<<30;
	int f = open("test.txt", O_RDONLY);
	if(!f) {
	    perror("test.txt");
	    simple_write(fd, "Could not find test.txt\r\n");
	} else {
	    char buff[4096];
	    int len;
	    while(max && (len = read(f, buff, sizeof(buff))) > 0) {
		int i;
		for(i = 0; i < len && max--; i++) {
		    if(buff[i] == '\n') {
			server_write(fd, "\r\n", 2, 0);
		    } else server_write(fd, buff+i, 1, 0);
		}
	    }
	    close(f);
	}
    } else if(!strcasecmp("colourshow", line) ||
              !strcasecmp("colorshow", line)) {
        colour_show(fd);
    } else if(!strcasecmp("colourshow256", line) ||
              !strcasecmp("colorshow256", line) ||
              !strcasecmp("colourshow2", line) ||
              !strcasecmp("colorshow2", line)) {
        colour_show256(fd);
    } else if(!strcasecmp("credits", line)) {
	simple_write(fd,
		"MCTS Copyright 2006-2009 Sebastian Andersson <http://bofh.diegeekdie.com/>\r\n"
		"This program comes with ABSOLUTELY NO WARRANTY.\r\n"
		"This is free software, and you are welcome to redistribute it\r\n"
		"under certain conditions.\r\n");

    } else if(!strcasecmp("eall", line)) {
	int i;
	for(i = 0; i < high_fd; i++) {
	    if(clients[i].is_connected) {
		simple_write(i, args);
		simple_write(i, "\r\n");
	    }
	}
    } else if(!strcasecmp("promptall", line)) {
	int i;
	for(i = 0; i < high_fd; i++) {
	    if(clients[i].is_connected) {
		simple_write(i, args);
	    }
	}
    } else if(!strcasecmp("echo", line)) {
        if(clients[fd].mode & SM_INVISIBLE) {
            server_visible(fd);
        } else {
            server_invisible(fd);
        }
    } else if(!strcasecmp("ident", line)) {
	simple_write(fd, "(processing)\r\n");
	ident(fd);
    } else if(!strcasecmp("quit", line)) {
        char buffer[100];
        simple_write(fd, "Bwye!\r\n");
        server_close(fd);
        buffer[0] = 0;
#ifdef NI_NUMERICHOST
        getnameinfo((const struct sockaddr *)&clients[fd].address,
                    clients[fd].address_len,
                    buffer, sizeof(buffer),
                    NULL, 0,
                    NI_NUMERICHOST);
#else
	strcpy(buffer, "unknown");
#endif
        buffer[sizeof(buffer)-1] = 0;
        printf("%s disconnected (quit, fd=%d)\n", buffer, fd);
        return;
    } else if(!strcasecmp("sendasis", line)) {
        simple_write(fd, args);
        simple_write(fd, "\r\n");
    } else if(!strcasecmp("senddata", line)) {
        send_data(fd, args);
    } else if(!strcasecmp("set", line)) {
        handle_set(fd, args);
    } else if(!strcasecmp("startmsp", line)) {
        telnet_enable_us_option(fd, MSPc);
    } else if(!strcasecmp("startmxp", line)) {
        telnet_enable_us_option(fd, MXPc);
    } else if(!strcasecmp("stopmccp", line)) {
        server_write(fd, "Stopping MCCP\r\n", 15, SW_FINISH|SW_DO_FLUSH);
    } else if(!strcasecmp("telnet", line)) {
        simple_write(fd,
                "TELNET and other codes:\r\n"
                "IAC  = FF  DONT = FE  DO   = FD  WONT = FC  WILL = FB\r\n"
                "MSP  = 5A  MXP  = 5B  ZMP  = 5D  END OF RECORD   = EF\r\n"
                "ESC  = 1B  [    = 5B  ]    = 5D\r\n"
                "\r\n");
    } else if(!strcasecmp("testansi", line)) {
        simple_write(fd, "\e[1;37;40mBright white \e[1;31mBright red.\e[37m\r\n");
        server_prompt(fd, "special prompt> ", 16);
	int delay = atoi(args);
	if(delay <= 0) delay = 1;
        sleep(delay);
        server_write(fd, "\r", 2, 0); /* Yes 2 in length! */
        simple_write(fd, "\e");
        sleep(delay);
        simple_write(fd, "[31mStill bright red\r\n"
                         "\e[mBack to the default colour.\r\n");
    } else if(!strcasecmp("testtext", line)) {
	test_text(fd, args);
    } else if(!strcasecmp("testcc", line)) {
        test_cc(fd, args);
    } else if(!strcasecmp("tt", line)) {
        telnet_turned_on_him_option(fd, TTc);
    } else if(!strcasecmp("zmp", line)) {
        handle_zmp(fd, args);
    } else if(*line) {
        simple_write(fd, "Unknown command: ");
        while(*line) {
            if(*line == IACc) server_write(fd, IAC, 1, 0);
            server_write(fd, line++, 1, 0);
        }
        simple_write(fd, "\r\n");
    }
    server_prompt(fd, "> ", 2);
}

int
main(int argc, char **argv)
{
    int port = 5445;
    signal(SIGPIPE, SIG_IGN);
    if(argc > 1) {
        port = atoi(argv[1]);
    }
    if(server_init(port) <= 0) {
        perror("Could not open the server port: ");
        exit(1);
    }
    printf("The server is now listening on port %d\n", daemon_port);
    while(1) {
        if(server_poll(60, 0) > 0) {
            int fd;
            if(server_pending()) {
                fd = server_accept();
                if(fd >= 0) {
                    char buffer[100];
                    buffer[0] = 0;
#ifdef NI_NUMERICHOST
                    getnameinfo((const struct sockaddr *)&clients[fd].address,
                                clients[fd].address_len,
                                buffer, sizeof(buffer),
                                NULL, 0,
                                NI_NUMERICHOST);
#else
		    strcpy(buffer, "unknown");
#endif
                    buffer[sizeof(buffer)-1] = 0;
                    printf("%s connected (fd=%d)\n", buffer, fd);
                    simple_write(fd, "\r\n" "\r\n"
                                     "Welcome to the Mud Client Test Server!\r\n"
                                     "Server version: " VERSION
				     " compiled at "
                                     __DATE__ "\r\n" "\r\n"
                                     "Write ? for help\r\n" "\r\n");
                    char empty[1];
                    empty[0]=0;
                    process_line(fd, empty);
                }
            }
            for(fd = 0; fd < high_fd; fd++) {
                if(server_ready(fd)) {
                    char *line = server_read(fd);
                    if(!line) {
                        char buffer[100];
                        server_close(fd);
                        buffer[0] = 0;
#ifdef NI_NUMERICHOST
                        getnameinfo((const struct sockaddr *)&clients[fd].address,
                                    clients[fd].address_len,
                                    buffer, sizeof(buffer),
                                    NULL, 0,
                                    NI_NUMERICHOST);
#else
			strcpy(buffer, "unknown");
#endif
                        buffer[sizeof(buffer)-1] = 0;
                        printf("%s disconnected (fd=%d)\n", buffer, fd);
                    } else process_line(fd, line);
                }
            }
        }
    }
    return 0;
}
