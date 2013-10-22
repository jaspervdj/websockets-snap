function appendOutput(cls, text) {
    $('#console-output').append('<pre class="' + cls + '">' + text + '</pre>');
    $('#line').focus();
}

$(document).ready(function () {
    var ws;

    $('#uri').focus();

    $('#login').submit(function () {
        var uri = $('#uri').val();
        $('#login').css('display', 'none');
        $('#console').css('display', 'block');

        ws = new WebSocket(uri);
        appendOutput('stderr', 'Opening WebSockets connection...\n');

        ws.onerror = function(event) {
            appendOutput('stderr', 'WebSockets error: ' + event.data + '\n');
        };

        ws.onopen = function() {
            appendOutput('stderr', 'WebSockets connection successful!\n');
        };

        ws.onclose = function() {
            appendOutput('stderr', 'WebSockets connection closed.\n');
        };

        ws.onmessage = function(event) {
            appendOutput('stdout', event.data);
        };

        return false;
    });

    $('#console-input').submit(function () {
        var line = $('#line').val();
        ws.send(line + '\n');
        appendOutput('stdin', line + '\n');
        $('#line').val('');
        return false;
    });
});
