# ReverseQR - Secure File & Text Sharing

A web application for sharing files and text between two devices without account or pervious contact.

## Why I did this
When I use a PC I do not trust (like a shool pc with an outdated wersion of windows and a diabled antivirus (for some reason I still have not figured out)) I do not want to plug in any USB sticḱ or open my password manager which is problematic since my passwords are 10+ characters long and randomly generated. I often resolve to typing them by hand, which is annoying.
Now, I can simply open up this website and scan the qr code to transfer anytnhing from my phne to the PC.

## Features

### Security
- **Diffie-Hellman Key Exchange**: Secure key establishment without pre-shared secrets
- **AES-256-GCM Encryption**: Encryption for all data
- **SHA-256 Hashing**: Automatic integrity verification of the shared secret to detect man in the middle attack
- **No Data Retention**: Files get deleted shortly after upload (default: 30 minutes)


### Easy use
1. **QR Code**: Receiver displays QR code, sender scans it
2. **Human-Readable Codes**: PGP wordlist encoding for easy verbal transmission

### A sumple but powerful tool:
- Text Message and File transfer 
- A sleek, Modern, responsive web interface
- No installation required on client machines
- Works on desktop and mobile browsers
- Zero-configuration for users



## Architecture

### Frontend
- **Vanilla JavaScript** - No frameworks required
- **Modern CSS** - Gradient designs and responsive layout
- **Native Crypto API** - For client-side encryption


### Backend
- **Express.js** - Lightweight HTTP server
- **Node.js Crypto** - Cryptographic operations
- **In-Memory Sessions** - Fast session management
- **Multer** - Secure file handling

### How to use?

**For Receiver:**
1. Open http://localhost:3000/
2. Share the QR code or PGP-encoded connection code with sender
3. Files/messages appear automatically when sent

**For Sender:**
1. Scan QR code or open /sender page and enter connection code
2. Type message and/or upload files
3. Click "Send Securely"
4. Sender gets the messages



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
- **3 word code** derived from encryption key to spot man in th middle attacks


## Deployment


## Quick Start (for testing with localhost)

> [!IMPORTANT]
> Reverseqr uses the crypto.sublte in the browser, which is only available in a secure context (localhost or https) therefore, the whole app will not work correctly if this is not the case (for exaple when testing using a second device on the same network).
In such condotions, the page will load, but not display any QR code or connection code and not permit any data tranfer this however indicates that the server is working fine
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
- Receiver: http://localhost:3000 (by default)
- Sender: http://localhost:3000/sender (by default)



### Production with Nginx

Please follow the instructions in SETUP.md


## 🛠️ API Endpoints

### Session Management
- `POST /api/session/create` - Create receiver session
- `POST /api/session/join` - Join as sender

### Key Exchange
- `POST /api/dh/exchange` - Exchange DH public keys

### Messaging
- `POST /api/message/send` - Send encrypted message/files
- `GET /api/message/retrieve/:code` - Retrieve messages
- `GET /api/file/download/:filename` - Download encrypted file

### Utilities
- `GET /health` - Health check
- `GET /` - Receiver page
- `GET /sender` - Sender page
- `GET /receiver` - Alternative receiver
- `GET /join?code=` - QR redirect


## 📈 Performance


- **File Handling**: Streaming capable for large files

## 🔍 Monitoring

### Check Status
```bash
pm2 status
```

### View Logs
```bash
pm2 logs reverseqr
```

### Monitor Resources
```bash
pm2 monit
```

## Limitations & Future Enhancements

### Current Limitations
- In-memory session storage (max ~1000 concurrent)
## License

GPL 3.0 License - See LICENSE file for details

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Support

For issues or questions:
1. Check the SETUP.md for deployment details
2. Review server logs with `pm2 logs reverseqr`
3. Test connectivity with `/health` endpoint


**Made with passion in Munich, Germany**
