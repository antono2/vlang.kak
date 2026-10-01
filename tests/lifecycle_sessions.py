#!/usr/bin/env python3
"""Real owning launcher plus tmux views survive a recovery restart."""
import os, shlex, subprocess, sys, tempfile, uuid
from pathlib import Path
from panes import wait_for, quote

repo=Path(__file__).resolve().parent.parent
kak=str(Path(sys.argv[1]).resolve())
name='vlang-recovery-'+uuid.uuid4().hex[:12]
with tempfile.TemporaryDirectory(prefix='vlang-recovery-') as directory:
    root=Path(directory);prefix=root/'prefix';bindir=root/'bin';bindir.mkdir()
    (bindir/'kak').symlink_to(kak)
    lsp=bindir/'kak-lsp';lsp.write_text("#!/bin/sh\nprintf 'declare-option str lsp_cmd \"\"\\n'\n");lsp.chmod(0o755)
    env={**os.environ,'PATH':str(bindir)+os.pathsep+os.environ['PATH'],'XDG_CONFIG_HOME':str(root/'config'),
         'XDG_CACHE_HOME':str(root/'cache'),'VLANG_KAK_SKIP_PULL':'1'}
    env.pop('VLANG_KAK_CONFIG_HOME',None)
    setup=subprocess.run([str(repo/'scripts/setup.sh'),'--prefix',str(prefix),'--no-build','--no-lsp','--no-vls','--no-explorer'],env=env,text=True,capture_output=True)
    assert setup.returncode==0,setup.stdout+setup.stderr
    first=root/'first.txt';second=root/'second.txt';first.write_text('first\nsecond\n');second.write_text('other\n')
    def tmux(*args): return subprocess.check_output(['tmux','-L',name,*args],env=env,text=True)
    def remote(client,command):
        subprocess.run([kak,'-p',name],input=f'evaluate-commands -client {quote(client)} %{{ {command} }}\n',env=env,text=True,check=True)
    def value(client,key,expression):
        path=root/key;path.unlink(missing_ok=True)
        remote(client,f'echo -to-file {quote(path)} {expression}')
        wait_for(lambda:path.exists() and path.read_text().strip(),key)
        return path.read_text().strip()
    try:
        command=shlex.join([str(prefix/'bin/kak-v'),'-s',name,'-e',f'echo -to-file {quote(root/"ready")} ready',str(first)])
        tmux('-f','/dev/null','new-session','-d','-s','test','-x','140','-y','40',command)
        wait_for((root/'ready').exists,'owner client')
        remote('client0','execute-keys iUnsaved<esc>; select 2.2,2.3; v-new-view')
        wait_for(lambda:len(tmux('list-panes','-F','#{pane_id}').splitlines())==2,'extra view')
        wait_for(lambda:value('client0','clients','%val{client_list}')=='client0 client1','second client')
        remote('client1',f'edit {quote(second)}; select 1.2,1.4')
        old=value('client0','oldpid','%val{client_pid}')
        (root/'ready').unlink()
        remote('client0','v-restart-recover-now')
        wait_for((root/'ready').exists,'restored owner ready')
        wait_for(lambda:value('client0','newpid','%val{client_pid}')!=old,'owner restart')
        wait_for(lambda:value('client0','clients-restored','%val{client_list}')=='client0 client1','restored view')
        assert value('client0','position0','%val{buffile} %val{selections_desc}')==f'{first} 2.2,2.3'
        assert value('client1','position1','%val{buffile} %val{selections_desc}')==f'{second} 1.2,1.4'
        remote('client0',f'write {quote(root/"recovered")}')
        assert (root/'recovered').read_text().startswith('Unsaved') and first.read_text().startswith('first')
        assert len(tmux('list-panes','-F','#{pane_id}').splitlines())==2
        print('ok - real recovery restart preserves unsaved source and multiple client buffers/selections')
    except Exception:
        try:
            for pane in tmux('list-panes','-F','#{pane_id}').splitlines(): print(tmux('capture-pane','-p','-t',pane))
            subprocess.run([kak,'-p',name],input=f"evaluate-commands -buffer '*debug*' %{{ write {quote(root/'debug')} }}\n",env=env,text=True,capture_output=True)
            if (root/'debug').exists(): print((root/'debug').read_text())
            for path in (prefix/'opt/vlang-kakoune').glob('restart.*/*'): print(path.name, path.read_text())
        except Exception as error: print('diagnostics:',error)
        raise
    finally:
        subprocess.run([kak,'-p',name],input='kill!\n',env=env,text=True,capture_output=True)
        subprocess.run(['tmux','-L',name,'kill-server'],env=env,capture_output=True)
