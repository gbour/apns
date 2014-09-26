-record(apns_state,{
	address,		%%Address of the apple push notification server
	port,			%%Port on which the apple's push notification server works
	ssl_certificate, 	%%This path of the certificate given by apple
	ssl_key, 	 	%%This is the ssl key
	ssl_socket,		%%SSL socket between webim and apns
	session_token_table	%%This stores the session_id, token pairs for iphone/ipod clients
	}). 
