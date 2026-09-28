const db = supabase.createClient('https://tnjyyxqvxygxgochayam.supabase.co', 'sb_publishable_93Ep4nz3AS1pjtuy2PeVXA_GI8mcvoK');
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const reais = n => Number(n).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const DIAS = ['Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'];

document.head.insertAdjacentHTML('beforeend', `<style>
:root{--bg:#0A0C10;--ink:#F1F5FA;--muted:#8E9AAB;--card:#12161D;--line:#242C38;--blue:#2F7BF0;--red:#D42B35;--ok:#5FD08F;--no:#F08A8A}
*{box-sizing:border-box}
body{margin:0;font-family:'Bricolage Grotesque',system-ui,sans-serif;background:var(--bg);color:var(--ink);min-height:100vh}
.pole{height:10px;background:repeating-linear-gradient(-45deg,var(--red) 0 14px,#fff 14px 28px,var(--blue) 28px 42px,#fff 42px 56px)}
main{max-width:640px;margin:0 auto;padding:22px 18px 60px}
h1{font-size:1.8rem;font-weight:800;letter-spacing:-.03em;margin:0 0 4px}
h2{font-size:1.2rem;margin:30px 0 12px}
a{color:var(--blue)}
.muted{color:var(--muted)}
input,select,button{font:inherit;color:var(--ink);border-radius:10px;border:1.5px solid var(--line);background:var(--card);padding:13px 12px;width:100%}
input:focus-visible,select:focus-visible,button:focus-visible{outline:3px solid var(--blue);outline-offset:2px}
select{color-scheme:dark}
button{cursor:pointer;font-weight:600;width:auto}
button.pri{background:var(--blue);border-color:var(--blue);color:#fff}
button.sel{border-color:var(--blue);background:#0F1B30}
form{display:grid;gap:10px}
.card{background:var(--card);border:1.5px solid var(--line);border-radius:12px;padding:14px}
.row{display:flex;justify-content:space-between;align-items:center;gap:10px}
.grade{display:flex;flex-wrap:wrap;gap:8px}
.lista{display:grid;gap:10px}
.tag{font-size:.8rem;font-weight:600;padding:4px 10px;border-radius:99px;background:#1A2230}
.tag.on{background:#12271C;color:var(--ok)}.tag.off{background:#2A1517;color:var(--no)}
.erro{color:var(--no);min-height:1.2em}.ok{color:var(--ok)}
[hidden]{display:none!important}
</style>`);

// Formulário de entrar / criar conta. Chama aoEntrar() quando logar.
function caixaLogin(el, aoEntrar, permitirCadastro = true) {
  el.innerHTML = `<form class="card" id="cxL"><b id="cxT">Entre para continuar</b>
    <input id="cxN" placeholder="Seu nome" hidden><input id="cxTel" type="tel" placeholder="Telefone com DDD" hidden>
    <input id="cxE" type="email" placeholder="E-mail" autocomplete="username" required>
    <input id="cxS" type="password" placeholder="Senha (mínimo 6 caracteres)" autocomplete="current-password" required>
    <button class="pri" type="submit" id="cxB">Entrar</button>
    ${permitirCadastro ? '<button type="button" id="cxM">Criar conta</button>' : ''}
    <div class="erro" id="cxR"></div></form>`;
  let criar = false;
  const R = $('cxR');
  if (permitirCadastro) $('cxM').onclick = () => {
    criar = !criar;
    $('cxN').hidden = $('cxTel').hidden = !criar;
    $('cxN').required = $('cxTel').required = criar;
    $('cxB').textContent = criar ? 'Criar conta' : 'Entrar';
    $('cxM').textContent = criar ? 'Já tenho conta' : 'Criar conta';
  };
  $('cxL').onsubmit = async e => {
    e.preventDefault(); R.textContent = '';
    const email = $('cxE').value.trim(), password = $('cxS').value;
    const r = criar
      ? await db.auth.signUp({ email, password, options: { data: { nome: $('cxN').value.trim(), telefone: $('cxTel').value.trim() } } })
      : await db.auth.signInWithPassword({ email, password });
    if (r.error) { R.textContent = criar ? 'Não foi possível criar a conta: ' + r.error.message : 'E-mail ou senha incorretos.'; return; }
    if (!r.data.session) { R.textContent = 'Conta criada. Confirme o e-mail que enviamos e depois entre.'; return; }
    aoEntrar();
  };
}
