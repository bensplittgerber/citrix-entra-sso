{
	"subject": { "commonName": {{ toJson .Subject.CommonName }} },
	"sans": [
		{ "type": "email", "value": {{ toJson .Subject.CommonName }} },
		{ "type": "userPrincipalName", "value": {{ toJson .Subject.CommonName }} }
	],
	"keyUsage": ["digitalSignature"],
	"extKeyUsage": ["clientAuth"],
	"crlDistributionPoints": ["http://pki.example.org/client/crl"]
}
