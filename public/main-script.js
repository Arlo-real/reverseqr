// Redirect to HTTPS if crypto.subtle is not available (required for encryption)
if (!window.crypto || !window.crypto.subtle) {
  if (window.location.protocol === 'http:') {
    window.location.href = window.location.href.replace('http:', 'https:');
  } else {
    alert('Your browser does not support the Web Crypto API. Please use a modern browser.');
  }
}

let connectionCode = null;
    let encryptionKey = null;
    let dhKeyPair = null;  // Our DH key pair
    let ws = null;  // WebSocket connection
    let wsToken = null;  // WebSocket authentication token
    let selectedFiles = []; // Will store: {name, size, file}
    let sentMessages = []; // Track sent messages for history
    let lastDisplayedSentMessageIndex = -1; // Track which sent messages have been displayed
    let displayedMessageIds = new Set(); // Track which messages have been displayed
    let maxFileSize = 8 * 1024 * 1024; // Default 8MB per file, will be updated from server
    let maxTotalSize = 30 * 1024 * 1024; // Max total request size (conservative: 30MB of 50MB limit)

    // Fetch max file size from server config on page load
    async function fetchMaxFileSize() {
      try {
        const response = await fetch('/api/config');
        const config = await response.json();
        if (config.maxFileSize) {
          maxFileSize = config.maxFileSize;
          // Adjust maxTotalSize to be 90% of body limit for safety
          maxTotalSize = Math.floor(config.bodySize * 0.9);
        }
      } catch (error) {
        console.warn('Could not fetch max file size from config:', error);
      }
    }

    // Set up WebSocket connection
    function setupWebSocket() {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${window.location.host}`;
      
      ws = new WebSocket(wsUrl);
      
      ws.onopen = () => {
        console.log('WebSocket connected');
        // Subscribe to session as main with auth token
        if (connectionCode && wsToken) {
          const subscribeMsg = {
            type: 'subscribe',
            code: connectionCode,
            role: 'main',
            token: wsToken
          };
          console.log('[MAIN WS] Subscribing with:', subscribeMsg);
          ws.send(JSON.stringify(subscribeMsg));
          
          // After reconnecting, check for any messages that may have been queued
          // while the connection was down
          if (encryptionKey) {
            fetchAndDisplayMessages();
          }
        }
      };
      
      ws.onmessage = async (event) => {
        try {
          const data = JSON.parse(event.data);
          console.log('WebSocket message:', data);
          
          if (data.type === 'sender-key-available' && data.responderPublicKey) {
            // Connector's public key is now available
            await handleSenderKeyAvailable(data.responderPublicKey);
          } else if (data.type === 'message-available') {
            // New message available, fetch it
            await fetchAndDisplayMessages();
          } else if (data.type === 'keys-available' && data.responderPublicKey) {
            // Keys were already available when we subscribed
            await handleSenderKeyAvailable(data.responderPublicKey);
          }
        } catch (error) {
          console.error('WebSocket message error:', error);
        }
      };
      
      ws.onclose = () => {
        console.log('WebSocket disconnected, attempting reconnect...');
        setTimeout(setupWebSocket, 2000);
      };
      
      ws.onerror = (error) => {
        console.error('WebSocket error:', error);
      };
    }

    // Handle when connector's public key becomes available
    async function handleSenderKeyAvailable(senderPublicKeyHex) {
      if (encryptionKey) {
        // Already have encryption key, ignore duplicate
        return;
      }
      
      console.log('Main: Got connector public key via WebSocket, computing shared secret');
      
      // Import connector's public key and compute shared secret
      const senderPublicKey = await importPublicKey(senderPublicKeyHex);
      const sharedSecret = await computeSharedSecret(dhKeyPair.privateKey, senderPublicKey);
      
      // Derive encryption key from shared secret using HKDF
      encryptionKey = await deriveKeyFromSharedSecret(sharedSecret);
      console.log('Main: Encryption key established via DH');
      
      // Display the security fingerprint and hide loading status
      try {
        const keyHash = await hashBuffer(encryptionKey);
        const keyWords = await hashToWords(keyHash);
        const keyHashDisplay = document.getElementById('keyHashDisplay');
        if (keyHashDisplay) {
          keyHashDisplay.innerHTML = `<strong>Security Fingerprint:</strong><br><span class="key-words">${keyWords}</span>`;
          keyHashDisplay.style.display = 'block';
        }
        // Hide the loading status
        const status = document.querySelector('.status');
        if (status) {
          status.style.display = 'none';
        }
        // Hide the QR code, connection code, and link after successful connection
        const qrSection = document.querySelector('.qr-section');
        if (qrSection) {
          qrSection.style.display = 'none';
        }
        // Show the send section
        const sendSection = document.getElementById('sendSection');
        if (sendSection) {
          sendSection.style.display = 'block';
        }
      } catch (hashError) {
        console.error('Error displaying key hash:', hashError);
      }
    }

    // Fetch and display messages (called when WebSocket notifies us)
    async function fetchAndDisplayMessages() {
      // Verify key exchange was completed before fetching messages
      if (!encryptionKey) {
        console.warn('Cannot fetch messages: encryption key not established yet');
        return;
      }

      try {
        const response = await fetch(`/api/message/retrieve/${connectionCode}`);
        
        if (response.status === 429) {
          await showRateLimitError();
          return;
        }
        
        const data = await response.json();

        if (data.messages && data.messages.length > 0) {
          console.log('Messages received:', data.messages);
          
          // Filter out already displayed messages
          const newMessages = data.messages.filter(msg => {
            const msgId = msg.timestamp || msg.data?.timestamp;
            return msgId && !displayedMessageIds.has(msgId);
          });
          
          if (newMessages.length > 0) {
            // Track these message IDs as displayed
            newMessages.forEach(msg => {
              const msgId = msg.timestamp || msg.data?.timestamp;
              if (msgId) displayedMessageIds.add(msgId);
            });
            displayMessages(newMessages);
          }
        }
      } catch (error) {
        console.error('Error fetching messages:', error);
      }
    }

    // Generate ECDH key pair in browser
    async function generateDHKeyPair() {
      const keyPair = await crypto.subtle.generateKey(
        { name: 'ECDH', namedCurve: 'P-256' },
        true,  // extractable
        ['deriveBits']
      );
      return keyPair;
    }

    // Export public key to hex string for transmission
    async function exportPublicKey(publicKey) {
      const exported = await crypto.subtle.exportKey('raw', publicKey);
      return Array.from(new Uint8Array(exported))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
    }

    // Import public key from hex string
    async function importPublicKey(hexString) {
      const bytes = new Uint8Array(hexString.match(/.{1,2}/g).map(b => parseInt(b, 16)));
      return await crypto.subtle.importKey(
        'raw',
        bytes,
        { name: 'ECDH', namedCurve: 'P-256' },
        true,
        []
      );
    }

    // Compute shared secret using ECDH
    async function computeSharedSecret(privateKey, otherPublicKey) {
      const sharedBits = await crypto.subtle.deriveBits(
        { name: 'ECDH', public: otherPublicKey },
        privateKey,
        256
      );
      return new Uint8Array(sharedBits);
    }

    async function initializeMain() {
      try {
        // Generate our DH key pair in the browser
        dhKeyPair = await generateDHKeyPair();
        const ourPublicKeyHex = await exportPublicKey(dhKeyPair.publicKey);
        console.log('Main: Generated DH key pair');

        // Create session and send our public key to server
        const response = await fetch('/api/session/create', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ initiatorDhPublicKey: ourPublicKeyHex })
        });
        
        if (response.status === 429) {
          await showRateLimitError();
          return;
        }
        
        const data = await response.json();

        connectionCode = data.code;
        wsToken = data.wsToken;  // Store WebSocket auth token
        document.getElementById('pgpCode').textContent = data.pgpCode;

        // Display QR URL in plain text
        const qrUrl = `${data.baseUrl}/join?code=${data.code}`;
        document.getElementById('qrUrl').textContent = qrUrl;

        // Display QR code (server-generated as data URL)
        const qrImage = document.getElementById('qrCode');
        qrImage.src = data.qrCode;

        // Set up WebSocket for real-time updates
        setupWebSocket();
      } catch (error) {
        showError('Failed to create session: ' + error.message);
        console.error(error);
      }
    }

    // Derive encryption key from shared secret using HKDF
    // Per RFC 5869 Section 3.1: when IKM (ECDH shared secret) is already 
    // uniformly random, a zero salt is acceptable as HKDF will use a 
    // hash-length string of zeros, which still provides proper extraction.
    async function deriveKeyFromSharedSecret(sharedSecret) {
      const keyMaterial = await crypto.subtle.importKey(
        'raw',
        sharedSecret,
        { name: 'HKDF' },
        false,
        ['deriveBits']
      );
      
      const derivedBits = await crypto.subtle.deriveBits(
        {
          name: 'HKDF',
          hash: 'SHA-256',
          salt: new Uint8Array(32),  // Zero salt - acceptable per RFC 5869 for uniformly random IKM
          info: new TextEncoder().encode('ReverseQR-Encryption-Key')
        },
        keyMaterial,
        256
      );
      
      return new Uint8Array(derivedBits);
    }

    async function displayMessages(messages) {
      const messagesSection = document.getElementById('messagesSection');
      const messagesList = document.getElementById('messagesList');
      messagesSection.style.display = 'block';

      // Only clear on first display (when messagesList is empty)
      if (messagesList.children.length === 0) {
        messagesList.innerHTML = '<div class="messages-title">Conversation</div>';
      }

      for (const msgWrapper of messages) {
        // Handle both direct msg.type and msg.data.type formats
        const msg = msgWrapper.data || msgWrapper;
        const msgDiv = document.createElement('div');
        msgDiv.className = 'message received-message';

        if (msg.type === 'text') {
          // Decrypt the text message - must have ciphertext
          let decrypted = '';
          
          if (msg.ciphertext && msg.iv && encryptionKey) {
            decrypted = await decryptText(msg.ciphertext, msg.iv, encryptionKey);
          } else if (msg.text) {
            // Fallback to plain text if no encryption
            decrypted = msg.text;
          } else {
            decrypted = '[Unable to decrypt message]';
          }

          msgDiv.innerHTML = `
            <div class="message-type">Text Message</div>
            <div class="message-text">${escapeHtml(decrypted).replace(/\n/g, '<br>')}</div>
          `;
        } else if (msg.type === 'files') {
          let filesHtml = '';
          if (msg.files && msg.files.length > 0) {
            filesHtml = await Promise.all(msg.files.map(async (f) => {
              let displayName = f.originalName;
              // Decrypt the file name if encrypted
              if (f.encryptedName && f.nameIv && encryptionKey) {
                displayName = await decryptText(f.encryptedName, f.nameIv, encryptionKey);
              }
              return `
                <div class="file-item-container">
                  <a href="#" class="file-item file-download-link" data-filename="${f.filename}" data-name="${displayName}" data-iv="${f.iv || ''}" data-size="${f.size || 0}" style="cursor: pointer;">${escapeHtml(displayName)}</a>
                </div>
              `;
            })).then(results => results.join(''));
          } else {
            filesHtml = '<p style="color: #999;">No files</p>';
          }
          
          msgDiv.innerHTML = `
            <div class="message-type">Files</div>
            <div class="message-files">
              ${filesHtml}
            </div>
          `;
        }

        // Insert right after the title to keep newest messages at top
        messagesList.insertBefore(msgDiv, messagesList.querySelector('.messages-title').nextSibling);
      }
    }

    function decryptMessage(ciphertext, iv, authTag) {
      // This is now called with encrypted data that needs decryption
      // Since we're using Web Crypto API on the client, we need async handling
      // For now, return a promise that will be handled in displayMessages
      try {
        if (!ciphertext) return '[No message content]';
        // Return hex string for async decryption
        return ciphertext;
      } catch (e) {
        console.error('Decryption error:', e);
        return '[Decryption failed]';
      }
    }

    async function decryptText(ciphertext, iv, encryptionKey) {
      try {
        if (!ciphertext || !iv) return '[No message content]';
        
        const ciphertextBuffer = hexToArray(ciphertext);
        const ivBuffer = hexToArray(iv);
        
        const key = await crypto.subtle.importKey(
          'raw',
          encryptionKey,
          { name: 'AES-GCM' },
          false,
          ['decrypt']
        );
        
        const decrypted = await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: ivBuffer
          },
          key,
          ciphertextBuffer
        );
        
        const decoder = new TextDecoder();
        return decoder.decode(decrypted);
      } catch (e) {
        console.error('Text decryption error:', e);
        return '[Decryption failed]';
      }
    }

    async function decryptFileData(encryptedBuffer, iv, encryptionKey) {
      try {
        if (!encryptedBuffer || !iv) return null;
        
        const ivBuffer = hexToArray(iv);
        
        const key = await crypto.subtle.importKey(
          'raw',
          encryptionKey,
          { name: 'AES-GCM' },
          false,
          ['decrypt']
        );
        
        const decrypted = await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: ivBuffer
          },
          key,
          encryptedBuffer
        );
        
        return decrypted;
      } catch (e) {
        console.error('File decryption error:', e);
        return null;
      }
    }

    function hexToArray(hex) {
      const bytes = [];
      for (let i = 0; i < hex.length; i += 2) {
        bytes.push(parseInt(hex.substr(i, 2), 16));
      }
      return new Uint8Array(bytes);
    }

    function verifyHash(data, expectedHash) {
      if (!expectedHash) return false;
      
      // Data can be either string or Uint8Array
      let buffer;
      if (typeof data === 'string') {
        buffer = new TextEncoder().encode(data);
      } else if (data instanceof Uint8Array) {
        buffer = data;
      } else {
        return false;
      }
      
      // Compute SHA256 of the data
      return crypto.subtle.digest('SHA-256', buffer).then(hashBuffer => {
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
        return hashHex === expectedHash;
      });
    }

    async function hashToWords(hashHex) {
      // Load EFF wordlist
      const response = await fetch('/eff_wordlist.json');
      const data = await response.json();
      const wordlist = data.eff_wordlist;
      const listLength = wordlist.length;
      
      // Convert hex hash to bytes
      const hashBytes = [];
      for (let i = 0; i < hashHex.length; i += 2) {
        hashBytes.push(parseInt(hashHex.substr(i, 2), 16));
      }
      
      // Take first 6 bytes (48 bits) of hash and split into 3 chunks
      // Each chunk is used with modulo to get wordlist index
      const words = [];
      for (let i = 0; i < 3; i++) {
        const byte1 = hashBytes[i * 2] || 0;
        const byte2 = hashBytes[i * 2 + 1] || 0;
        const twoBytes = (byte1 << 8) | byte2;
        const index = twoBytes % listLength;
        words.push(wordlist[index]);
      }
      
      return words.join(' ');
    }

    async function downloadFile(filename, originalName, iv, hash, fileSize) {
      try {
        console.log('[RECEIVER] Downloading file:', originalName, 'Size:', fileSize);
        if (!iv) {
          alert('Missing IV for file decryption - file cannot be decrypted');
          return;
        }
        
        if (!encryptionKey) {
          alert('Encryption key not available - unable to decrypt file');
          return;
        }
        
        // Warn user if file is large (> 50MB)
        if (fileSize > 52428800) {
          const fileSizeMB = (fileSize / 1048576).toFixed(2);
          const proceed = confirm(`This file is ${fileSizeMB} MB. Downloading and decrypting large files may take a moment. Please be patient.\n\nContinue?`);
          if (!proceed) return;
        }
        
        // Fetch the encrypted file from the server
        const response = await fetch(`/api/file/download/${encodeURIComponent(filename)}`);
        
        if (response.status === 429) {
          await showRateLimitError();
          return;
        }
        
        if (!response.ok) {
          alert(`Failed to download file: ${response.statusText}`);
          return;
        }
        
        // Get the file as an array buffer
        const encryptedBuffer = await response.arrayBuffer();
        
        // Decrypt the file
        const decryptedBuffer = await decryptFileData(encryptedBuffer, iv, encryptionKey);
        if (!decryptedBuffer) {
          alert('Failed to decrypt file');
          return;
        }
        
        // Verify hash if provided
        if (hash) {
          const hashArray = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', decryptedBuffer)));
          const computedHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
          
          if (computedHash !== hash) {
            alert('Warning: Hash verification failed! The file may have been corrupted or tampered with.');
          }
        }
        
        // Create a download link for the decrypted file
        const blob = new Blob([decryptedBuffer]);
        const url = window.URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = originalName;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        window.URL.revokeObjectURL(url);
      } catch (error) {
        console.error('Error downloading file:', error);
        alert(`Error downloading file: ${error.message}`);
      }
    }

    async function sendMessage() {
      try {
        console.log('[MAIN] sendMessage() called');
        if (!connectionCode) {
          showError('Not connected to connector');
          return;
        }

        // Verify key exchange was completed successfully
        if (!encryptionKey) {
          showError('Secure connection not established. Key exchange may have failed. Please reconnect.');
          return;
        }

        const text = document.getElementById('mainTextInput').value;
        if (!text.trim() && selectedFiles.length === 0) {
          showError('Please enter a message or select files');
          return;
        }

        const sendBtn = document.getElementById('mainSendBtn');
        sendBtn.disabled = true;
        sendBtn.innerHTML = '<span class="spinner"></span><span class="spinner"></span><span class="spinner"></span> Sending...';

        // Send text message if present
        if (text) {
          const textFormData = new FormData();
          textFormData.append('code', connectionCode);
          textFormData.append('messageType', 'text');
          
          // Encrypt the text using AES-256-GCM
          const encoder = new TextEncoder();
          const textData = encoder.encode(text);
          
          // Import the encryptionKey for use with Web Crypto API
          const key = await crypto.subtle.importKey(
            'raw',
            encryptionKey,
            { name: 'AES-GCM' },
            false,
            ['encrypt']
          );
          
          const iv = crypto.getRandomValues(new Uint8Array(12)); // 96-bit IV is optimal for AES-GCM per NIST
          const ivHex = arrayToHex(iv);
          const encrypted = await crypto.subtle.encrypt(
            {
              name: 'AES-GCM',
              iv: iv
            },
            key,
            textData
          );
          
          const ciphertextHex = arrayToHex(new Uint8Array(encrypted));
          
          textFormData.append('ciphertext', ciphertextHex);
          textFormData.append('iv', ivHex);
          textFormData.append('authTag', '');
          
          console.log('[MAIN] Sending text to /api/message/send/main with code:', connectionCode);
          const response = await fetch('/api/message/send/main', {
            method: 'POST',
            body: textFormData
          });

          if (response.status === 429) {
            await showRateLimitError();
            return;
          }

          if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Send text failed');
          }
        }
        
        // Send files if present
        if (selectedFiles.length > 0) {
          const formData = new FormData();
          formData.append('code', connectionCode);
          formData.append('messageType', 'files');
          
          const key = await crypto.subtle.importKey(
            'raw',
            encryptionKey,
            { name: 'AES-GCM' },
            false,
            ['encrypt']
          );
          
          for (let fileMetadata of selectedFiles) {
            const fileBuffer = await fileMetadata.file.arrayBuffer();
            const fileUint8Array = new Uint8Array(fileBuffer);
            const iv = crypto.getRandomValues(new Uint8Array(12)); // 96-bit IV is optimal for AES-GCM per NIST
            const ivHex = arrayToHex(iv);
            
            // Encrypt the file name
            const fileNameKey = await crypto.subtle.importKey(
              'raw',
              encryptionKey,
              { name: 'AES-GCM' },
              false,
              ['encrypt']
            );
            const fileNameIv = crypto.getRandomValues(new Uint8Array(12)); // 96-bit IV is optimal for AES-GCM per NIST
            const fileNameIvHex = arrayToHex(fileNameIv);
            const fileNameEncoder = new TextEncoder();
            const fileNameData = fileNameEncoder.encode(fileMetadata.name);
            const encryptedFileName = await crypto.subtle.encrypt(
              {
                name: 'AES-GCM',
                iv: fileNameIv
              },
              fileNameKey,
              fileNameData
            );
            const encryptedFileNameHex = arrayToHex(new Uint8Array(encryptedFileName));
            
            const encrypted = await crypto.subtle.encrypt(
              {
                name: 'AES-GCM',
                iv: iv
              },
              key,
              fileUint8Array
            );
            
            // Create a new File object with encrypted data
            const encryptedBlob = new Blob([new Uint8Array(encrypted)], { type: 'application/octet-stream' });
            // Use generic filename to avoid transmitting original filename
            const genericFilename = `encrypted_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
            const encryptedFile = new File(
              [encryptedBlob],
              genericFilename,
              { type: 'application/octet-stream' }
            );
            
            formData.append('files', encryptedFile);
            formData.append('fileIvs[]', ivHex);
            formData.append('fileNames[]', encryptedFileNameHex);
            formData.append('fileNameIvs[]', fileNameIvHex);
          }
          
          const response = await fetch('/api/message/send/main', {
            method: 'POST',
            body: formData
          });

          if (response.status === 429) {
            await showRateLimitError();
            return;
          }

          if (!response.ok) {
            let errorMessage = 'Send files failed';
            try {
              const contentType = response.headers.get('content-type');
              if (contentType && contentType.includes('application/json')) {
                const error = await response.json();
                errorMessage = error.error || errorMessage;
              } else {
                errorMessage = `Server error: ${response.status} ${response.statusText}`;
              }
            } catch (parseError) {
              errorMessage = `Server error: ${response.status} ${response.statusText}`;
            }
            throw new Error(errorMessage);
          }
        }

        showSuccess('Message sent securely!');
        
        // Track sent messages for history
        if (text.trim()) {
          sentMessages.push({
            type: 'text',
            text: text,
            files: [],
            timestamp: Date.now()
          });
        }
        
        if (selectedFiles.length > 0) {
          sentMessages.push({
            type: 'files',
            text: '',
            files: selectedFiles.map(f => ({
              name: f.name,
              size: f.size
            })),
            timestamp: Date.now()
          });
        }
        
        displaySentMessages();
        
        document.getElementById('mainTextInput').value = '';
        
        // Clear file contents from memory to free RAM
        selectedFiles.forEach(f => {
          if (f.file) {
            f.file = null; // Release file reference
          }
        });
        selectedFiles = [];
        renderFilesList();

        sendBtn.disabled = false;
        sendBtn.innerHTML = 'Send Securely';
      } catch (error) {
        showError('Send failed: ' + error.message);
        console.error('Send error details:', error);
        document.getElementById('mainSendBtn').disabled = false;
        document.getElementById('mainSendBtn').innerHTML = 'Send Securely';
      }
    }

    function arrayToHex(arr) {
      return Array.from(arr).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function copyCode() {
      const codeElement = document.getElementById('pgpCode');
      const text = codeElement.textContent;
      navigator.clipboard.writeText(text).then(() => {
        const button = event.target;
        button.textContent = 'Copied!';
        button.classList.add('copied');
        setTimeout(() => {
          button.textContent = 'Copy Code';
          button.classList.remove('copied');
        }, 2000);
      });
    }

    function showError(message) {
      const errorDiv = document.getElementById('error');
      errorDiv.textContent = message;
      errorDiv.style.display = 'block';
    }

    function showSuccess(message) {
      // Create success div if it doesn't exist
      let successDiv = document.getElementById('success');
      if (!successDiv) {
        successDiv = document.createElement('div');
        successDiv.id = 'success';
        successDiv.className = 'success';
        const errorDiv = document.getElementById('error');
        if (errorDiv && errorDiv.parentNode) {
          errorDiv.parentNode.insertBefore(successDiv, errorDiv.nextSibling);
        }
      }
      successDiv.textContent = message;
      successDiv.style.display = 'block';
      setTimeout(() => {
        successDiv.style.display = 'none';
      }, 3000);
    }

    async function showRateLimitError() {
      const errorDiv = document.getElementById('error');
      
      // Fetch available images and pick one at random
      let imageSrc = '/429/Calm down you must.webp'; // fallback
      try {
        const response = await fetch('/api/429-images');
        const data = await response.json();
        if (data.images && data.images.length > 0) {
          const randomImage = data.images[Math.floor(Math.random() * data.images.length)];
          imageSrc = `/429/${encodeURIComponent(randomImage)}`;
        }
      } catch (e) {
        console.error('Failed to fetch 429 images:', e);
      }
      
      errorDiv.innerHTML = `
        <div style="text-align: center;">
          <img src="${imageSrc}" alt="Rate Limited" style="max-width: 300px; margin-bottom: 15px; border-radius: 8px;">
          <p><strong>Too Many Requests</strong></p>
          <p>You're being rate limited. Please wait a moment before trying again.</p>
        </div>
      `;
      errorDiv.style.display = 'block';
      
      // Hide other sections
      const qrSection = document.querySelector('.qr-section');
      if (qrSection) qrSection.style.display = 'none';
      const status = document.querySelector('.status');
      if (status) status.style.display = 'none';
    }

    function escapeHtml(unsafe) {
      return unsafe
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
    }

    // Event delegation for file download links
    document.addEventListener('click', function(e) {
      const link = e.target.closest('.file-download-link');
      if (link) {
        e.preventDefault();
        const filename = link.dataset.filename;
        const name = link.dataset.name;
        const iv = link.dataset.iv;
        const hash = link.dataset.hash;
        const size = parseInt(link.dataset.size) || 0;
        downloadFile(filename, name, iv, hash, size);
      }
    });

    // File handling for main
    function handleFileSelect(files) {
      for (let file of files) {
        // Check for duplicates
        if (selectedFiles.some(f => f.name === file.name && f.size === file.size)) {
          continue;
        }
        
        // Validate individual file size (accounting for hex encoding ~2x and form overhead)
        const encryptedSize = file.size * 2.2; // Hex encoding + overhead
        if (encryptedSize > maxFileSize) {
          showError(`File "${file.name}" is too large (${formatFileSize(file.size)} → ${formatFileSize(encryptedSize)} when encrypted). Maximum is ${formatFileSize(maxFileSize)}.`);
          continue;
        }
        
        // Calculate total encrypted request size with new file
        const currentTotalEncrypted = selectedFiles.reduce((sum, f) => sum + (f.size * 2.2), 0);
        const newFileTotalEncrypted = currentTotalEncrypted + encryptedSize;
        if (newFileTotalEncrypted > maxTotalSize) {
          showError(`Adding "${file.name}" would exceed total upload limit. Current: ${formatFileSize(newFileTotalEncrypted)}, Max: ${formatFileSize(maxTotalSize)}`);
          continue;
        }
        
        selectedFiles.push({
          name: file.name,
          size: file.size,
          file: file
        });
      }
      renderFilesList();
    }

    function renderFilesList() {
      const filesList = document.getElementById('mainFilesList');
      filesList.innerHTML = '';
      
      selectedFiles.forEach((file, index) => {
        const fileItem = document.createElement('div');
        fileItem.className = 'file-item';
        fileItem.innerHTML = `
          <span>${escapeHtml(file.name)} <span class="file-size">(${formatFileSize(file.size)})</span></span>
          <button class="remove-file" data-index="${index}">Remove</button>
        `;
        filesList.appendChild(fileItem);
      });
    }

    function formatFileSize(bytes) {
      if (bytes === 0) return '0 Bytes';
      const k = 1024;
      const sizes = ['Bytes', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + ' ' + sizes[i];
    }

    function displaySentMessages() {
      const messagesSection = document.getElementById('messagesSection');
      const messagesList = document.getElementById('messagesList');
      
      // Show messages section if it has messages
      if (messagesSection && messagesList && (messagesList.children.length > 0 || sentMessages.length > 0)) {
        messagesSection.style.display = 'block';
      }
      
      // Only display NEW messages that haven't been displayed yet
      for (let i = lastDisplayedSentMessageIndex + 1; i < sentMessages.length; i++) {
        const msg = sentMessages[i];
        const msgDiv = document.createElement('div');
        msgDiv.className = 'message received-message';
        
        if (msg.type === 'text' && msg.text) {
          msgDiv.innerHTML = `
            <div class="message-text">${escapeHtml(msg.text).replace(/\n/g, '<br>')}</div>
          `;
        } else if (msg.files && msg.files.length > 0) {
          const filesHtml = msg.files.map(f => `
            <div class="file-item-container">
              <span class="file-item">${escapeHtml(f.name)} <span class="file-size">(${formatFileSize(f.size)})</span></span>
            </div>
          `).join('');
          msgDiv.innerHTML = `
            <div class="message-files">${filesHtml}</div>
          `;
        }
        
        // Insert at beginning to keep newest messages at top
        messagesList.insertBefore(msgDiv, messagesList.firstChild);
        lastDisplayedSentMessageIndex = i; // Update tracking index
      }
    }

    // Event delegation for remove file buttons
    document.addEventListener('click', function(e) {
      if (e.target.classList.contains('remove-file')) {
        const index = parseInt(e.target.dataset.index);
        selectedFiles.splice(index, 1);
        renderFilesList();
      }
    });

    // Set up drag and drop for file upload
    function setupDragAndDrop() {
      const fileUploadArea = document.getElementById('fileUploadArea');
      const fileInput = document.getElementById('mainFileInput');
      
      if (!fileUploadArea || !fileInput) return;
      
      fileUploadArea.addEventListener('click', () => fileInput.click());
      
      fileInput.addEventListener('change', (e) => {
        handleFileSelect(e.target.files);
        fileUploadArea.classList.remove('active');
      });
      
      fileUploadArea.addEventListener('dragover', (e) => {
        e.preventDefault();
        fileUploadArea.classList.add('active');
      });
      
      fileUploadArea.addEventListener('dragleave', () => {
        fileUploadArea.classList.remove('active');
      });
      
      fileUploadArea.addEventListener('drop', (e) => {
        e.preventDefault();
        fileUploadArea.classList.remove('active');
        handleFileSelect(e.dataTransfer.files);
      });
    }

    // Initialize on page load
    window.addEventListener('DOMContentLoaded', () => {
      initializeMain();
      setupDragAndDrop();
      fetchMaxFileSize();
      
      // Set up copy code button event listener
      const copyCodeBtn = document.getElementById('copyCodeBtn');
      if (copyCodeBtn) {
        copyCodeBtn.addEventListener('click', copyCode);
      }

      // Set up send button event listener
      const mainSendBtn = document.getElementById('mainSendBtn');
      if (mainSendBtn) {
        mainSendBtn.addEventListener('click', sendMessage);
      }
    });

    async function hashBuffer(buffer) {
      const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    }