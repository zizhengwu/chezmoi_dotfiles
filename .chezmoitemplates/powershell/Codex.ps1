function codexyolo {
    $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
    $env:HTTP_PROXY = 'http://127.0.0.1:7890'
    $env:NO_PROXY = 'localhost,127.0.0.1,::1'

    codex --yolo @args
}
