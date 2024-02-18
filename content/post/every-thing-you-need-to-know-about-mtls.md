---
title: "Every Thing You Need to Know About mTLS"
date: 2024-02-07T16:31:52+08:00
lastmod: 2024-02-07T16:31:52+08:00
keywords: ["https", "mTLS"]
tags: ["https", "mTLS"]
categories: ["http/https"]
summary: ""
draft: true
---

## What is mTLS

mTLS, or Mutual TLS, is an extension of the Transport Layer Security (TLS) protocol that ensures both the client and the server authenticate each other during the TLS handshake. While traditional TLS only requires the server to present a certificate to prove its identity, mTLS requires both the server and the client to exchange and validate certificates.

mTLS steps in to address this by establishing a two-way authentication process. Both the server and the client authenticate each other using digital certificates, ensuring that both parties are who they claim to be. This mutual authentication creates a trusted communication channel resistant to impersonation and man-in-the-middle attacks.

### Understanding TLS

To appreciate mTLS, it's essential to have a fundamental understanding of TLS. TLS is the successor to Secure Sockets Layer (SSL) and works by encrypting the data transmitted between a web server and a web browser, making it unreadable to eavesdroppers. The TLS protocol involves the following key steps:

1. **Handshake**: The client and server establish a connection and agree on the version of TLS and the encryption algorithms (cipher suite) to use.
2. **Server Authentication**: The server presents a certificate (usually signed by a trusted CA) to prove its identity to the client.
3. **Key Exchange**: The client and server generate session keys for encryption, often using asymmetric encryption to securely exchange these keys.
4. **Secure Communication**: With the session keys in place, the client and server can communicate securely with symmetric encryption, where both sides encrypt and decrypt data using shared secret keys.

TLS ensures that any data transmitted between the client and server remains confidential and is not tampered with, providing integrity and privacy.

### How mTLS works

mTLS enhances the standard TLS handshake process by adding an additional step where the client also presents its certificate to the server for authentication. Here's how the mTLS handshake typically works:

1. **Initiation**: The client begins the TLS handshake by sending a "ClientHello" message, indicating its willingness to establish a connection.
2. **Server Certificate**: The server responds with a "ServerHello" message, followed by its certificate and a "CertificateRequest" message, which signals that the client must also provide a certificate.
3. **Client Certificate**: The client then sends its certificate to the server. If the client does not have a certificate or the certificate is invalid, the server may terminate the connection.
4. **Verification**: The server verifies the client's certificate, ensuring it is signed by a trusted CA and has not expired or been revoked.
5. **Key Exchange and Secure Communication**: Like in the standard TLS handshake, the server and client exchange keys, and secure communication begins.

During this process, both the client and the server perform cryptographic checks to ensure the other's certificate is valid and trustworthy. If either party's certificate fails validation, the handshake is aborted, and the communication is not established, thus preventing unauthorized access.

## How to create self-signed certificate with OpenSSL

Script to generate self-signed certificate.

```bash
#!/bin/bash

# Set the validity duration
DAYS=36500

# Set the desired CN and SAN for the server and client
SERVER_CN="server_common_name"
SERVER_SAN="DNS:server.example.com,IP:127.0.0.1"

CLIENT_CN="client_common_name"
CLIENT_SAN="DNS:client.example.com,IP:127.0.0.1"

# Create a configuration file for adding SAN - Server
cat > server_ext.cnf <<EOF
basicConstraints=CA:FALSE
nsCertType=server
nsComment="OpenSSL Generated Server Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
keyUsage=nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SERVER_SAN
EOF

# Create a configuration file for adding SAN - Client
cat > client_ext.cnf <<EOF
basicConstraints=CA:FALSE
nsCertType=client, email
nsComment="OpenSSL Generated Client Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
keyUsage=nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage=clientAuth, emailProtection
subjectAltName=$CLIENT_SAN
EOF

# Generate the CA key and certificate
echo "Generating CA key..."
openssl genrsa -out ca.key 2048

echo "Generating CA certificate..."
openssl req -x509 -new -nodes -key ca.key -sha256 -days $DAYS -out ca.crt -subj "/CN=YourCAName"

# Generate the server key and CSR
echo "Generating server key..."
openssl genrsa -out server.key 2048

echo "Generating server CSR..."
openssl req -new -key server.key -out server.csr -subj "/CN=$SERVER_CN"

# Generate the server certificate and sign it with the CA
echo "Generating server certificate..."
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days $DAYS -sha256 -extfile server_ext.cnf

# Generate the client key and CSR
echo "Generating client key..."
openssl genrsa -out client.key 2048

echo "Generating client CSR..."
openssl req -new -key client.key -out client.csr -subj "/CN=$CLIENT_CN"

# Generate the client certificate and sign it with the CA
echo "Generating client certificate..."
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days $DAYS -sha256 -extfile client_ext.cnf

# Cleanup CSR files and config files as they are no longer needed
rm server.csr client.csr server_ext.cnf client_ext.cnf

echo "Certificate generation completed."
echo "CA, server, and client certificates are in the current directory."
```

### **Step #1 - Create Root CA Certificate and Key**

#### **Step 1.1 - Generate Root CA Private Key:**

We’ll generate a RSA type private key that is 2048 bits in length. Longer the key, harder it becomes to crack the key, and therefore more secure.

```
openssl genrsa -out ca-key.pem 2048
```

#### **Step 1.2 - Generate Root CA Certificate**

Now, let’s generate the CA certificate using the CA private key generated in the previous step. The certificate will be valid for next 365 days.

```
openssl req -new -x509 -nodes -days 365 -key ca-key.pem -out ca-cert.pem
```

The above command will prompt you for additional details about your company, org, internal domain name of the CA for which the certificate is being requested.

### **Step #2 - Create Server Certificate and Key**

#### **Step 2.1 - Generate Server Private Key and Server CSR**

The following command will create a new server private key and a server certificate signing request(CSR).

```
openssl req -newkey rsa:2048 -nodes -days 365 \
   -keyout server-key.pem \
   -out server-req.pem
```

The above command will prompt you for additional details about your company, org, internal domain name of the server for which the certificate is being requested.

#### **Step 2.2 - Server Certificate Creation and Signing using CA Key.**

We’ll use the CAKey and CA cert file to sign the server CSR.

```
openssl x509 -req -days 365 -set_serial 01 \
   -in server-req.pem \
   -out server-cert.pem \
   -CA ca-cert.pem \
   -CAkey ca-key.pem \
   -extensions SAN   \
   -extfile <(printf "\n[SAN]\nsubjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth")
```

Just providing `CommonName or CN` in the CSR is not enough. Using CN is obsolete. You should add the `SubjectAlternateName or SAN` extension to the certificate. Otherwise, you may get an error shown below when using the certificate without the SAN extension.

`x509: certificate relies on legacy Common Name field, use SANs instead`

For added security, we should restrict the certificate to be used by a SSL/TLS/HTTPS server application only and not by any SSL/TLS/HTTPS client application. For this purpose, we’ll use the `ExtendedKeyUsage` key with a value of `serverAuth`

### **Step #3 - Create Client Certificate and Key**

#### **Step 3.1 - Generate Client Private Key and Client CSR**

```
openssl req -newkey rsa:2048 -nodes -days 365 \
   -keyout client-key.pem \
   -out client-req.pem
```

#### **Step 3.2 - Client Certificate Creation and Signing using CA Key**

We’ll use the CAKey and CA cert file to sign the client CSR.

```
openssl x509 -req -days 365 -set_serial 01  \
   -in client-req.pem    -out client-cert.pem  \
   -CA ca-cert.pem   \
   -CAkey ca-key.pem   \
   -extensions SAN  \
   -extfile <(printf "\n[SAN]\nsubjectAltName=DNS:localhost\nextendedKeyUsage=clientAuth")
```

For added security, we should restrict the certificate to be used by a SSL/TLS/HTTPS client application only and not by any SSL/TLS/HTTPS server application. For this purpose, we’ll use the `ExtendedKeyUsage` key with a value of `clientAuth`

### **Step #4 - Inspect the Certificates**

Use the following command to dump the certificates and visually inspect various fields in the certificate.

```
$ openssl x509 -in client-cert.pem -noout -text
```

Use following command to verify the certificate is correct.

```
$ openssl verify -CAfile ca-cert.pem client-cert.pem
```

## How to setup HTTPS server and client with TLS certificate

### Simple HTTPS server with mTLS

```go
package main

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"os"
	"path/filepath"
)

var (
	CACertFilePath = "certs/ca.crt"
	CertFilePath   = "certs/server.crt"
	KeyFilePath    = "certs/server.key"
)

func main() {
	pwd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	CACertFilePath = filepath.Join(pwd, CACertFilePath)
	CertFilePath = filepath.Join(pwd, CertFilePath)

	cer, err := tls.LoadX509KeyPair(CertFilePath, KeyFilePath)
	if err != nil {
		panic(err)
	}

	certPool := x509.NewCertPool()
	caCertPEM, err := os.ReadFile(CACertFilePath)
	if err != nil {
		panic(err)
	}
	if !certPool.AppendCertsFromPEM(caCertPEM) {
		panic("failed to append ca cert")
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{cer},
		ClientCAs:    certPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
	}

	server := http.Server{
		Addr:      ":4443",
		TLSConfig: config,
		Handler:   http.HandlerFunc(HelloServer),
	}
	defer server.Close()
	err = server.ListenAndServeTLS("", "")
	if err != nil {
		panic(err)
	}
}

func HelloServer(w http.ResponseWriter, req *http.Request) {
	w.Write([]byte("This is an example server.\n"))
}
```

### Simple HTTPS client with mTLS

```go
package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

var (
	CACertFilePath = "certs/ca.crt"
	CertFilePath   = "certs/client.crt"
	KeyFilePath    = "certs/client.key"
)

func main() {
	msg := httpsClient("https://localhost:4443")
	fmt.Println("Msg: ", string(msg))
}

func httpsClient(url string) []byte {
	pwd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	CACertFilePath = filepath.Join(pwd, CACertFilePath)
	CertFilePath = filepath.Join(pwd, CertFilePath)

	clientTLSCert, err := tls.LoadX509KeyPair(CertFilePath, KeyFilePath)
	if err != nil {
		panic(err)
	}
	// Configure the client to trust TLS server certs issued by a CA.
	certPool, err := x509.SystemCertPool()
	if err != nil {
		panic(err)
	}
	if caCertPEM, err := os.ReadFile(CACertFilePath); err != nil {
		panic(err)
	} else if ok := certPool.AppendCertsFromPEM(caCertPEM); !ok {
		panic("invalid cert in CA PEM")
	}
	tlsConfig := &tls.Config{
		RootCAs:      certPool,
		Certificates: []tls.Certificate{clientTLSCert},
	}
	tr := &http.Transport{
		TLSClientConfig: tlsConfig,
	}
	client := &http.Client{Transport: tr}
	resp, err := client.Get(url)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	fmt.Println("Response status:", resp.Status)
	msg, _ := io.ReadAll(resp.Body)
	return msg
}
```

Run the client and server, you will get the response log like:

```
Response status: 200 OK
Msg:  This is an example server.
```

Use Wireshark to capture packages, and you’ll find:

![https](/post/every-thing-you-need-to-know-about-mtls/wireshark.png)

## References
- [Mutual TLS Authentication - Everything you need to know](https://www.bastionxp.com/mutual-tls)
- [How to create self-signed SSL TLS X.509 certificates using OpenSSL](https://www.bastionxp.com/blog/how-to-create-self-signed-ssl-tls-x.509-certificates-using-openssl/)
- [How to setup your own CA with OpenSSL](https://gist.github.com/soarez/9688998)
- [How to setup HTTPS web server in Golang with self-signed SSL TLS certificate](https://www.bastionxp.com/blog/golang-https-web-server-self-signed-ssl-tls-x509-certificate/)
- [How to setup HTTPS client in Golang with self-signed SSL TLS client certificate](https://www.bastionxp.com/blog/golang-https-client-self-signed-ssl-tls-x509-certificate/)
- [Go HTTPS server with mTLS](https://gist.github.com/Wenfeng-GAO/4a279370caca2132da317ac3c8fe29d6)
