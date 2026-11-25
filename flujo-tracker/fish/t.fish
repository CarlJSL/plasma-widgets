function t --description 'Flujo de tickets: elige uno, muestra el comando, deja la frase en el portapapeles y abre la sesión'
    set -l rows (python3 ~/.local/bin/flujo --list)
    or begin; echo "flujo falló (¿falta instalarlo? ./install.sh en flujo-tracker)"; return 1; end
    test (count $rows) -gt 0; or begin; echo "Sin tickets abiertos"; return 0; end

    # clave, fase, título y qué sigue; el resto (comandos y frase) viaja en la fila
    set -l sel (printf '%s\n' $rows | fzf --delimiter \t --with-nth 2,1,3,4 --prompt 'ticket> ' --height 70% --reverse)
    test -n "$sel"; or return 0

    set -l f (string split \t -- $sel)
    set -l cmds (string split ';;' -- $f[5])
    set -l cmd $cmds[1]
    if test (count $cmds) -gt 1
        set cmd (printf '%s\n' $cmds | fzf --prompt 'repo> ' --height 30% --reverse)
        test -n "$cmd"; or return 0
    end

    if qdbus6 org.kde.klipper /klipper setClipboardContents "$f[6]" >/dev/null 2>&1
        echo "Frase copiada: pégala en Claude con Ctrl+Shift+V"
    else
        echo "Frase (cópiala): $f[6]"
    end
    echo "→ $cmd"
    eval $cmd
end
