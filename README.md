# ReverseQR - Secure File & Text Sharing

A web application for sharing files and text between two devices without account or previous contact.
Try it [here](https://reverseqr.qzz.io/) (uptime not guaranteed)

## Why I did this
When I use a PC I do not trust (like a school PC with an outdated version of Windows and a disabled antivirus (for some reason I still have not figured out)), I do not want to plug in any USB stick or open my password manager, which is problematic since my passwords are 10+ characters long and randomly generated. I often resolve to typing them by hand, which is annoying.
Now, I can simply open up this website and scan the QR code to transfer anything from my phone to the PC.

## Features

### Security
- **End-to-end encryption**: The server does not see what is being sent (only the size)
- **No Data Retention**: Files get deleted shortly after upload (default: 30 minutes)

### Privacy
- No user tracking (no cookies, no browser fingerprinting, no nothing)
- Sessions expire after a short amount of time (15 min by default)
- All data deleted shortly after upload (30 min by default)

### Easy use: two ways of transmitting the connection code
- **QR Code**: Main displays QR code, connector scans it
- **Human-Readable Codes**: PGP wordlist encoding for easy verbal transmission

### A simple but powerful tool:
- Text message and file transfer 
- A sleek, modern, responsive web interface
- No installation or configuration required by clients (all in browser)


## Limitations
- High RAM usage for the connector and main
- A malicious server admin could replace the normal webpage with one that does not encrypt the data and the user would not be able to notice



## How to use?

**For Main:****
1. Open http://localhost:3000/
2. Share the QR code or PGP-encoded connection code with connector
3. Files/messages appear automatically when sent

**For Connector:**
1. Scan QR code or open /connect page and enter connection code
2. Type message and/or upload files
3. Click "Send Securely"
4. Main gets the messages



## Encryption Details

### Key Exchange
1. Both parties generate DH key pairs
2. Public keys are exchanged via the server
3. Shared secret is computed locally
4. Encryption key is derived using HKDF-SHA256

### Message Encryption
- **Algorithm**: AES-256-GCM (Galois/Counter Mode)
- **Key Size**: 256 bits
- **IV**: 16 random bytes per message
- **3-word code** derived from encryption key to spot man-in-the-middle attacks


## Deployment:


### Quick Start (for testing with localhost)

> [!IMPORTANT]
> Reverseqr uses the crypto.sublte in the browser, which is only available in a secure context (localhost or https) therefore, the whole app will not work correctly if this is not the case (for example when testing using a second device on the same network).
In such conditions, the page will load, but not display any QR code or connection code and not permit any data transfer. This however indicates that the server is working fine.
[More info](https://developer.mozilla.org/en-US/docs/Web/API/Crypto/subtle)

### Installation

1. **Clone and navigate to project:**
```bash
cd reverseqr/
```

2. **Install dependencies:**
```bash
npm install
```

3. **Start the server:**
```bash
npm start
```

4. **Access the application:**
- Main: http://localhost:3000 (by default)
- Connector: http://localhost:3000/connect (by default)



### Production with Nginx

Please follow the instructions in SETUP.md


## API Endpoints

### Session Management
- `POST /api/session/create` - Create main session with strict rate limiting
- `POST /api/session/join` - Join existing session as connector (only one connector per session)
- `GET /api/session/status/:code` - Get session status and DH public keys

### Messaging & Files
- `POST /api/message/send` - Send encrypted message or file
- `GET /api/message/retrieve/:code` - Retrieve encrypted messages for a connection
- `GET /api/file/download/:filename` - Download encrypted file

### Configuration & Utilities
- `GET /api/config` - Get server configuration (max sizes, timeouts, etc.)
- `GET /api/429-images` - List images for 429 rate limit error page
- `GET /api/404-images` - List images for 404 error page
- `GET /health` - Server health check

### Pages
- `GET /` - Main page displaying QR code
- `GET /connect` - Page to enter connection code
- `GET /join?code=` - Redirects to connector page and auto-connects

### WebSocket
- WebSocket server for real-time notifications (message available, keys exchanged, etc.)


## Limitations & Future Enhancements

### Current Limitations
- In-memory session storage (max ~1000 concurrent)
## License

GPL 3.0 License - See LICENSE file for details

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Basic troubleshooting

1. Test connectivity with `/health` endpoint
2. Make sure you are using localhost, not your local IP
3. Try using the setupscript
4. Reboot yourself (sleep) and try again


**Made with passion in Munich, Germany**
