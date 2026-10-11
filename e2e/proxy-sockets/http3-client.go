package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/quic-go/quic-go/http3"
)

func main() {
	// Isolated test CA only. This client has no TCP fallback.
	transport := &http3.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: "sockets.example.test"}}
	defer transport.Close()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	request, err := http.NewRequest(http.MethodGet, "https://127.0.0.1/client-ip", nil)
	if err != nil {
		panic(err)
	}
	request.Host = "sockets.example.test"
	response, err := client.Do(request)
	if err != nil {
		panic(err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 3 || response.StatusCode != 200 {
		panic(response.Status)
	}
	fmt.Print(response.Proto + " ")
	if _, err := io.Copy(os.Stdout, response.Body); err != nil {
		panic(err)
	}
}
