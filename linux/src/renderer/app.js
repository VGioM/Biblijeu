// app.js — l'interface de Biblijeu : barre latérale, grille de jaquettes,
// panneau d'informations, vue des mises à jour, vue des sauvegardes, réglages.
(function () {
  'use strict';
  const S = window.Shared;
  const { esc, menu, menuFromButton, sheet, h } = window.UI;
  const $ = (id) => document.getElementById(id);
  const api = window.api;

  let items = [], emulators = [], states = {}, status = null;
  const ui = { search: '', selected: null };
  const set = (k) => status.settings[k];
  const sel = () => set('lastSelection') || 'all';
  const st = (id) => states[id] || {};
  const byId = (id) => items.find((i) => i.id === id);
  const fileURL = (p) => 'file://' + p.split('/').map(encodeURIComponent).join('/');

  // ── Émulateur d'un jeu (même règle que main.js) ─────────────────────────

  function emulatorFor(it) {
    if (it.kind !== 'rom') return null;
    const s = S.SYSTEM_BY_ID[it.systemID];
    const ok = (e) => e && e.systems.includes(it.systemID);
    const find = (id) => emulators.find((e) => e.id === id);
    if (st(it.id).emulatorID && find(st(it.id).emulatorID)) return find(st(it.id).emulatorID);
    if (!s) return null;
    const pref = set('emulatorForSystem')[s.id];
    if (pref && ok(find(pref))) return find(pref);
    for (const id of s.emulators) if (find(id)) return find(id);
    return emulators.find((e) => e.systems.includes(s.id)) || null;
  }
  const playable = (it) => it.kind !== 'rom' || !!emulatorFor(it);
  const ctx = () => ({ states, playable, hidden: (id) => !!st(id).hidden });

  function coverURL(it) {
    const s = st(it.id);
    if (s.customArtworkPath) return { url: fileURL(s.customArtworkPath), fit: true };
    if (s.artworkURL) return { url: s.artworkURL, fit: true };
    if (it.localArtwork) return { url: fileURL(it.localArtwork), fit: true, icon: /\.svg$|icons|pixmaps/.test(it.localArtwork) };
    return null;
  }

  function coverHTML(it, style) {
    const c = coverURL(it);
    let html = `<div class="cover" style="background-image:${UI.placeholder(it.sortTitle)};${style || ''}">`;
    if (c) {
      // Une icône d'application n'a pas de fond flou : elle est centrée, à taille raisonnable.
      if (c.icon) html += `<img class="art fit" loading="lazy" src="${esc(c.url)}" style="padding:22%" onerror="this.remove()">`;
      else html += `<div class="blur" style="background-image:url('${esc(c.url)}')"></div><img class="art fit" loading="lazy" src="${esc(c.url)}" onerror="this.parentNode.querySelector('.blur')&&this.parentNode.querySelector('.blur').remove();this.remove()">`;
    } else html += `<div class="ph">${icon(S.symbolOf(it), 26)}</div>`;
    return html;
  }

  function cardHTML(it) {
    const fav = st(it.id).favorite;
    const sys = S.SYSTEM_BY_ID[it.systemID];
    const badge = it.kind === 'rom' && sys ? sys.shortName : it.steamGameID ? 'Steam' : it.systemID === 'windows' ? 'Windows' : S.KIND_LABEL[it.kind];
    return `${coverHTML(it)}
      <div class="hover"><button class="circle" data-act="play" ${playable(it) ? '' : 'disabled'} title="Jouer">${icon('play', 15)}</button><button class="circle" data-act="info" title="Informations">${icon('info', 16)}</button></div>
      <div class="badges"><span class="badge">${esc(badge)}</span>${it.discs.length > 1 ? `<span class="badge">${it.discs.length} disques</span>` : ''}</div>
      ${playable(it) ? '' : `<div class="warn" title="Aucun émulateur installé pour cette console">${icon('warning', 15)}</div>`}</div>
      <div class="t1">${esc(it.title)}</div>
      <div class="t2">${esc(S.subtitle(it))}${fav ? ` <span class="fav">${icon('heartFill', 9)}</span>` : ''}</div>`;
  }

  // ── Barre latérale ───────────────────────────────────────────────────────

  function renderSidebar() {
    const counts = S.counts(items, ctx());
    const outdated = emulators.filter((e) => e.kind === 'flatpak' && status.flatpakUpdates[e.target]).length;
    const row = (id, title, ic, count, extra) => `<button class="side-row${sel() === id ? ' active' : ''}" data-sel="${esc(id)}">${icon(ic)}<span class="label">${esc(title)}</span>${extra || (count ? `<span class="count">${count}</span>` : '')}</button>`;
    let html = '<h3>Bibliothèque</h3>';
    for (const s of S.SECTIONS) {
      if (s.id === 'updates') html += row(s.id, s.title, s.icon, 0, outdated ? `<span class="count warm">${outdated}</span>` : '');
      else if (s.id === 'backups') html += row(s.id, s.title, s.icon, 0, set('autoBackup') && set('backupDestination') && !status.backup.available ? `<span class="count warm" title="Disque de sauvegarde absent — rien n'est copié pour l'instant.">${icon('warning', 13)}</span>` : '');
      else if (s.id === 'all' || counts[s.id]) html += row(s.id, s.title, s.icon, counts[s.id]);
    }
    const systems = S.SYSTEMS.filter((s) => counts['system:' + s.id]).sort((a, b) => S.collator.compare(a.name, b.name));
    if (systems.length) html += '<h3>Consoles</h3>' + systems.map((s) => row('system:' + s.id, s.name, s.symbol, counts['system:' + s.id])).join('');
    const roots = set('romFolders');
    if (roots.length > 1) html += '<h3>Dossiers</h3>' + roots.map((p) => row('source:' + p, p.split('/').pop(), 'folder', counts['source:' + p])).join('');
    $('sidebar').innerHTML = html;
    $('sidefoot').innerHTML = `<button class="link" data-act="addRomFolder">${icon('folderPlus')}${roots.length ? 'Ajouter un dossier…' : 'Ajouter un dossier de ROM…'}</button>
      <button class="link" data-act="settings">${icon('gear')}Réglages…</button>`;
  }

  // ── Barre d'outils ───────────────────────────────────────────────────────

  function renderToolbar(list) {
    $('title').textContent = S.sectionTitle(sel());
    let sub = '';
    if (status.isScanning) sub = status.scanProgress;
    else if (status.isFetchingArtwork) sub = `Recherche des jaquettes… ${Math.round(status.artworkProgress * 100)} %`;
    else if (sel() === 'updates') sub = `${emulators.length} émulateur${emulators.length > 1 ? 's' : ''} installé${emulators.length > 1 ? 's' : ''}`;
    else if (sel() === 'backups') sub = status.backup.progress || (status.backup.groups.length ? `${status.backup.groups.length} source${status.backup.groups.length > 1 ? 's' : ''} de sauvegardes` : '');
    else if (list.length) sub = `${list.length} élément${list.length > 1 ? 's' : ''}`;
    $('subtitle').textContent = sub;
    $('progress').innerHTML = status.isFetchingArtwork || status.isScanning ? '<span class="spinner"></span>' : '';
    const it = ui.selected && byId(ui.selected);
    $('playSel').disabled = !it || !playable(it);
  }

  // ── Grille ───────────────────────────────────────────────────────────────

  let mode = null;
  function emptyState(ic, title, msg, action, act) {
    return `<div class="empty"><div class="big">${icon(ic, 46)}</div><div class="t">${esc(title)}</div><div class="m">${esc(msg)}</div>${action ? `<button class="btn primary large" data-act="${act}">${esc(action)}</button>` : ''}</div>`;
  }

  function renderContent(list) {
    const c = $('content');
    const s = sel();
    if (s === 'updates') { mode = 'updates'; c.innerHTML = updatesHTML(); return; }
    if (s === 'backups') { mode = 'backups'; c.innerHTML = backupsHTML(); return; }
    if (!list.length) {
      mode = 'empty';
      if (status.isScanning && !items.length) c.innerHTML = `<div class="empty"><span class="spinner large"></span><div class="m">${esc(status.scanProgress || 'Analyse…')}</div></div>`;
      else if (!set('romFolders').length && !items.length) c.innerHTML = emptyState('gamepad', 'Aucun jeu pour l\'instant', 'Ajoutez le dossier qui contient vos ROM : Biblijeu reconnaît les consoles, retrouve les jaquettes et lance chaque jeu avec le bon émulateur. Vos jeux Steam apparaissent tout seuls.', 'Ajouter un dossier de ROM…', 'addRomFolder');
      else c.innerHTML = ui.search ? emptyState('search', 'Aucun résultat', `Rien ne correspond à « ${ui.search} ».`) : emptyState('gamepad', 'Rien à afficher ici', 'Aucun jeu ne correspond à cette catégorie.');
      return;
    }
    if (mode !== 'grid') { c.innerHTML = '<div class="grid" id="items"></div>'; mode = 'grid'; }
    document.documentElement.style.setProperty('--card-min', `${set('cardSize') || 168}px`);
    UI.patchList($('items'), list, (it) => it.id, cardHTML, (it) => `card${ui.selected === it.id ? ' selected' : ''}`);
  }

  // ── Panneau d'informations ───────────────────────────────────────────────

  let planCache = { key: null, value: null };
  async function refreshPlan(it) {
    const key = JSON.stringify([it.id, st(it.id), set('directLaunch'), set('resumeOnLaunch'), set('protonVersion'), emulators.map((e) => e.id)]);
    if (planCache.key === key) return;
    planCache = { key, value: null };
    const [plan, resume, prefix] = await Promise.all([api.call('plan', it.id), api.call('resumeInfo', it.id), it.systemID === 'windows' ? api.call('prefixPath', it.id) : null]);
    planCache = { key, value: { plan, resume, prefix } };
    renderInspector(true);
  }

  function section(title, body) { return body ? `<div class="sec"><div class="sec-title">${esc(title)}</div>${body}</div>` : ''; }

  function inspectorHTML(it) {
    const s = st(it.id);
    const emu = emulatorFor(it);
    const info = planCache.value;
    const resumes = info && info.resume && info.resume.request.type !== 'fromStart';
    const sys = S.SYSTEM_BY_ID[it.systemID];
    const primary = it.kind !== 'rom' && it.systemID !== 'windows' ? (it.kind === 'emulator' ? 'Ouvrir' : 'Jouer') : resumes ? 'Reprendre' : 'Jouer';
    let html = `<div class="insp">
      <div style="box-shadow:0 7px 28px rgba(0,0,0,.5);border-radius:12px">${coverHTML(it, 'border-radius:12px')}</div></div>
      <div><h2>${esc(it.title)}</h2><div class="muted">${esc(S.subtitle(it))}</div>
        ${it.languages && it.languages.length ? `<div class="tertiary" style="font-size:11.5px">${esc(it.languages.join(' · '))}</div>` : ''}
        ${s.lastPlayed ? `<div class="tertiary" style="font-size:11.5px">Joué ${esc(UI.relativeDate(s.lastPlayed))} · ${s.playCount || 0} fois</div>` : ''}</div>
      <div class="hstack">
        <button class="btn primary large grow" data-act="play" ${playable(it) ? '' : 'disabled'}>${icon(resumes ? 'playCircle' : 'play', 14)}${primary}</button>
        ${resumes ? `<button class="btn large icon" data-act="playFromStart" title="Démarrer depuis le début, sans charger de sauvegarde">${icon('restart', 14)}</button>` : ''}
        <button class="btn large icon" data-act="fav" title="Ajouter aux favoris">${icon(s.favorite ? 'heartFill' : 'heart', 15)}</button>
      </div>`;

    if (it.discs.length > 1) {
      html += section('Disques', it.discs.map((d, i) => `<div class="disc"><span class="grow" style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">Disque ${i + 1} — ${esc(d.split('/').pop())}</span><button class="btn" data-act="playDisc" data-i="${i}">${icon('play', 11)}</button></div>`).join(''));
    }

    // Émulateur
    if (it.kind === 'rom' && it.systemID !== 'windows') {
      const alts = emulators.filter((e) => e.systems.includes(it.systemID));
      html += section('Émulateur', alts.length
        ? `<select data-k="emulatorID"><option value="">Automatique${emu ? ` (${esc(emu.name)})` : ''}</option>${alts.map((e) => `<option value="${e.id}" ${s.emulatorID === e.id ? 'selected' : ''}>${esc(e.name)} — ${e.kind === 'flatpak' ? 'Flatpak' : e.kind === 'appimage' ? 'AppImage' : 'paquet'}</option>`).join('')}</select>`
        : `<div class="notice">${icon('warning', 15)}<div>Aucun émulateur installé pour ${esc(sys ? sys.name : 'cette console')}.${sys && sys.emulators.length ? `<div class="muted">Installez ${esc(sys.emulators.slice(0, 3).map((id) => S.EMULATOR_BY_ID[id] && S.EMULATOR_BY_ID[id].name).filter(Boolean).join(', '))} — section « Mises à jour ».</div>` : ''}</div></div>`);
    }

    // Proton
    if (it.systemID === 'windows' && !it.steamGameID) {
      html += section('Proton', status.protons.length
        ? `<select data-k="protonVersion"><option value="">Réglage général (${esc(set('protonVersion') || status.protons[0])})</option>${status.protons.map((p) => `<option ${s.protonVersion === p ? 'selected' : ''}>${esc(p)}</option>`).join('')}</select>
           <div class="muted" style="font-size:11.5px">Lancé ${status.hasUmu ? 'par umu-run, dans le conteneur Steam Linux Runtime,' : 'par Proton'} avec un préfixe propre à ce jeu.</div>
           ${info && info.prefix ? `<div class="hstack"><button class="btn grow" data-act="openPrefix">${icon('folder', 13)}Préfixe du jeu</button></div>` : ''}`
        : `<div class="notice">${icon('warning', 15)}<div>Aucun Proton trouvé. Installez « Proton Experimental » depuis Steam (Bibliothèque → Outils), ou GE-Proton avec ProtonPlus.</div></div>`);
    }

    // Steam
    if (it.steamGameID) {
      html += section('Steam', `<div class="muted" style="font-size:11.5px">Lancé par Steam, avec ${it.systemID === 'windows' ? 'le Proton choisi pour ce jeu dans Steam' : 'ses réglages'}.</div>`);
    }

    // Sauvegarde d'état
    if (it.kind === 'rom' && emu && it.systemID !== 'windows') {
      let body;
      if (!emu.resume) body = `<div class="muted" style="font-size:11.5px">${esc(emu.name)} ne sait pas charger une sauvegarde d'état au démarrage. Le jeu démarrera depuis le début.</div>`;
      else {
        body = '';
        if (emu.resumeKinds.includes('slot')) {
          body += `<select data-k="resumeSlot"><option value="">${emu.resumeKinds.includes('auto') ? 'Dernière sauvegarde' : 'Emplacement 1'}</option>${Array.from({ length: 10 }, (_, i) => `<option value="${i + 1}" ${s.resumeSlot === i + 1 ? 'selected' : ''}>Emplacement ${i + 1}</option>`).join('')}</select>`;
        } else if (emu.resumeKinds.includes('auto')) body += '<div class="muted" style="font-size:11.5px">Reprend la sauvegarde la plus récente de ce jeu.</div>';
        if (emu.resumeKinds.includes('file')) {
          if (s.stateFilePath) body += `<div class="hstack" style="font-size:11.5px">${icon('doc', 13)}<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(s.stateFilePath.split('/').pop())}</span></div>`;
          body += `<div class="hstack"><button class="btn" data-act="stateFile">${s.stateFilePath ? 'Changer…' : "Fichier d'état…"}</button>${s.stateFilePath ? '<button class="btn" data-act="forgetState">Oublier</button>' : ''}</div>`;
        }
        if (!set('resumeOnLaunch')) body += '<div class="muted" style="font-size:11.5px">« Reprendre au lancement » est désactivé dans les réglages : le bouton Jouer démarre depuis le début.</div>';
      }
      html += section("Sauvegarde d'état", body);
    }

    // Fichier et commande
    html += section('Fichier', `<div class="row"><div class="k">Chemin</div><div class="v">${esc(it.path)}</div></div>
      ${it.fileSize ? `<div class="row"><div class="k">Taille</div><div class="v">${esc(S.bytes(it.fileSize))}</div></div>` : ''}
      ${it.tags && it.tags.length ? `<div class="row"><div class="k">Étiquettes</div><div class="v">${esc(it.tags.join(', '))}</div></div>` : ''}
      ${info && info.plan && info.plan.preview ? `<div class="cmd">${esc(info.plan.preview)}</div>` : ''}
      ${info && info.plan && info.plan.error ? `<div class="muted" style="font-size:11.5px;white-space:pre-wrap">${esc(info.plan.error)}</div>` : ''}
      <div class="hstack"><button class="btn grow" data-act="reveal">${icon('folder', 13)}Dossier</button>${info && info.plan && info.plan.preview ? `<button class="btn grow" data-act="copyCmd">${icon('copy', 13)}Commande</button>` : ''}</div>`);

    // Jaquette
    html += section('Jaquette', `<div class="hstack"><button class="btn grow" data-act="artSearch">Rechercher</button><button class="btn grow" data-act="artCorrect">Autre titre…</button><button class="btn grow" data-act="artFile">Image…</button></div>
      ${s.searchTitle ? `<div class="muted" style="font-size:11.5px">Titre de recherche : ${esc(s.searchTitle)}</div>` : ''}`);

    // Classement
    const kinds = ['rom', 'game', 'emulator', 'other'];
    html += section('Classement', `<div class="hstack"><span style="width:64px" class="muted">Type</span><select class="grow" data-k="kindOverride"><option value="">Automatique</option>${kinds.map((k) => `<option value="${k}" ${s.kindOverride === k ? 'selected' : ''}>${esc(S.KIND_LABEL[k])}</option>`).join('')}</select></div>
      ${it.kind === 'rom' || it.kind === 'game' ? `<div class="hstack"><span style="width:64px" class="muted">Console</span><select class="grow" data-k="systemOverride"><option value="">Automatique</option>${S.SYSTEMS.map((x) => `<option value="${x.id}" ${s.systemOverride === x.id ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></div>` : ''}
      <div><button class="linkbtn muted" data-act="hide">${s.hidden ? 'Afficher dans la bibliothèque' : 'Masquer de la bibliothèque'}</button></div>`);
    return html + '</div>';
  }

  let lastInsp = null;
  function renderInspector(force) {
    const insp = $('inspector');
    const it = ui.selected && byId(ui.selected);
    const show = it && set('showInspector') && !['updates', 'backups'].includes(sel());
    if (!show) { insp.classList.add('hidden'); lastInsp = null; return; }
    insp.classList.remove('hidden');
    refreshPlan(it);
    const html = inspectorHTML(it);
    if (html !== lastInsp || force) { const top = insp.scrollTop; insp.innerHTML = html; insp.scrollTop = top; lastInsp = html; }
  }

  // ── Mises à jour ─────────────────────────────────────────────────────────

  function emuIcon(e) { return `<div class="ico">${e.icon ? `<img src="${esc(fileURL(e.icon))}" onerror="this.remove()">` : icon('cpu', 16)}</div>`; }
  const kindLabel = (e) => ({ flatpak: `Flatpak ${e.installation === 'user' ? '(utilisateur)' : '(système)'}`, native: 'paquet', appimage: 'AppImage', proton: 'Steam' }[e.kind]);

  function updatesHTML() {
    const act = status.emulatorActivity, notes = status.emulatorNotes, probs = status.emulatorProblems;
    const line = (e, extra) => {
      const upd = e.kind === 'flatpak' && status.flatpakUpdates[e.target];
      const sub = act[e.id] ? `<div class="s">${esc(act[e.id])}</div>` : probs[e.id] ? `<div class="s warm">${esc(probs[e.id])}</div>` : notes[e.id] ? `<div class="s ok">${esc(notes[e.id])}</div>`
        : `<div class="s">${esc([kindLabel(e), e.version ? `version ${e.version}` : null, upd ? `→ ${upd}` : null].filter(Boolean).join(' · '))}</div>`;
      return `<div class="lrow">${emuIcon(e)}<div class="names"><div class="t">${esc(e.name)}</div>${sub}</div>${extra || ''}
        ${act[e.id] ? '<span class="spinner"></span>' : ''}
        ${e.github || e.homepage ? `<button class="btn plain icon" data-act="openURL" data-url="${esc(e.github ? `https://github.com/${e.github}/releases/latest` : e.homepage)}" title="Page du projet">${icon('external', 14)}</button>` : ''}</div>`;
    };
    const flat = emulators.filter((e) => e.kind === 'flatpak');
    const outdated = flat.filter((e) => status.flatpakUpdates[e.target]);
    const upToDate = flat.filter((e) => !status.flatpakUpdates[e.target]);
    const others = emulators.filter((e) => e.kind !== 'flatpak');
    const checked = status.updatesCheckedAt ? `Vérifié ${UI.relativeDate(status.updatesCheckedAt)}.` : 'Pas encore vérifié.';
    let html = `<div class="page">
      <div class="summary">${icon(outdated.length ? 'downCircle' : 'checkCircle', 22)}<div style="flex:1"><b>${outdated.length ? `${outdated.length} mise${outdated.length > 1 ? 's' : ''} à jour disponible${outdated.length > 1 ? 's' : ''}` : flat.length ? 'Vos émulateurs Flatpak sont à jour' : 'Aucun émulateur Flatpak'}</b>
        <div class="muted" style="font-size:11.5px">${esc(checked)} Les émulateurs Flatpak sont vérifiés une fois par jour ; ceux en paquet se mettent à jour avec le système, les AppImage depuis la page du projet.</div></div>
        ${status.isCheckingUpdates ? '<span class="spinner"></span>' : `<button class="btn" data-act="checkUpdates" ${status.hasFlatpak ? '' : 'disabled'}>Vérifier maintenant</button>`}
        ${outdated.length ? '<button class="btn primary" data-act="updateAll">Tout mettre à jour</button>' : ''}</div>
      <label class="check"><input type="checkbox" data-setting="autoInstallUpdates" ${set('autoInstallUpdates') ? 'checked' : ''}><span>Installer automatiquement les mises à jour<div class="help muted" style="font-size:11.5px">Après la vérification du jour, pour les Flatpak installés pour l'utilisateur (ceux du système demandent un mot de passe).</div></span></label>`;
    if (outdated.length) html += `<h2>À mettre à jour</h2><div class="list">${outdated.map((e) => line(e, `<span class="pillw">${esc(status.flatpakUpdates[e.target])}</span><button class="btn primary" data-act="updateEmu" data-id="${e.id}" ${status.emulatorActivity[e.id] ? 'disabled' : ''}>Mettre à jour</button>`)).join('')}</div>`;
    if (upToDate.length) html += `<h2>À jour</h2><div class="list">${upToDate.map((e) => line(e)).join('')}</div>`;
    if (others.length) html += `<h2>Paquets, AppImage et Proton</h2><div class="list">${others.map((e) => line(e)).join('')}</div>`;
    if (status.missing.length) {
      html += `<h2>Non installés</h2><div class="list">${status.missing.map((m) => `<div class="lrow"><div class="ico">${icon('cpu', 16)}</div><div class="names"><div class="t">${esc(m.name)}</div>
        <div class="s ${status.emulatorProblems[m.id] ? 'warm' : status.emulatorNotes[m.id] ? 'ok' : ''}">${esc(status.emulatorActivity[m.id] || status.emulatorProblems[m.id] || status.emulatorNotes[m.id] || m.systems.slice(0, 6).map((x) => S.SYSTEM_BY_ID[x] && S.SYSTEM_BY_ID[x].shortName).filter(Boolean).join(', ') + ` · ${m.flatpak}`)}</div></div>
        ${status.emulatorActivity[m.id] ? '<span class="spinner"></span>' : `<button class="btn" data-act="installEmu" data-id="${m.id}" ${status.hasFlatpak ? '' : 'disabled'}>Installer</button>`}</div>`).join('')}</div>`;
    }
    return html + '</div>';
  }

  // ── Sauvegarde ───────────────────────────────────────────────────────────

  function backupsHTML() {
    const b = status.backup;
    const dest = set('backupDestination');
    const kinds = set('backupKinds'), excluded = set('backupExcludedEmulators');
    const totals = {};
    for (const g of b.groups) for (const f of g.folders) { const t = totals[f.folder.kind] || (totals[f.folder.kind] = { n: 0, bytes: 0 }); t.n++; t.bytes += f.bytes; }
    let html = `<div class="page">
      <div class="summary">${icon('drive', 22)}<div style="flex:1;min-width:0"><b>${dest ? esc(dest) : 'Aucun dossier de sauvegarde'}</b>
        <div class="muted" style="font-size:11.5px">${!dest ? 'Choisissez un dossier — un disque externe, par exemple. Les copies vont dans « Biblijeu Sauvegardes ».' : b.available ? (b.lastRun ? `Dernière vérification ${UI.relativeDate(b.lastRun)}.` : 'Jamais sauvegardé.') : 'Disque absent : rien n\'est copié pour l\'instant.'}</div></div>
        <button class="btn" data-act="chooseDest">${dest ? 'Changer…' : 'Choisir…'}</button>${dest && b.available ? `<button class="btn plain icon" data-act="openDest" title="Ouvrir">${icon('folder', 15)}</button>` : ''}</div>
      <div class="hstack">${b.isRunning ? `<span class="spinner"></span><span class="grow muted">${esc(b.progress || 'Copie…')}</span><button class="btn" data-act="cancelBackup">Arrêter</button>`
        : `<button class="btn primary" data-act="backupNow" ${dest && b.available ? '' : 'disabled'}>${icon('drive', 14)}Sauvegarder maintenant</button><button class="btn" data-act="restoreAll" ${dest && b.available ? '' : 'disabled'}>Tout restaurer…</button><span class="grow"></span>${b.isScanning ? '<span class="spinner"></span>' : ''}`}</div>
      ${b.message ? `<div class="notice" data-act="clearBackupMsg">${icon('info', 15)}<div>${esc(b.message)}</div></div>` : ''}
      ${b.lastSummary ? `<div class="muted" style="font-size:12px">${esc(b.lastSummary)}</div>` : ''}
      ${b.lastFailures.length ? `<div class="notice" style="color:var(--warm)">${icon('warning', 15)}<div>${b.lastFailures.map(esc).join('<br>')}</div></div>` : ''}
      <div class="group"><div class="gtitle">Automatique</div>
        <label class="check"><input type="checkbox" data-setting="autoBackup" ${set('autoBackup') ? 'checked' : ''}><span>Sauvegarder automatiquement<div class="help muted" style="font-size:11.5px">La partie la plus récente gagne, qu'elle soit sur ce PC ou sur le disque. Rien n'est jamais supprimé.</div></span></label>
        <div class="hstack" style="padding-left:23px"><label class="check"><input type="checkbox" data-setting="backupOnInterval" ${set('backupOnInterval') ? 'checked' : ''}><span>Toutes les</span></label><input type="number" min="1" max="1440" style="width:70px" data-setting="backupIntervalMinutes" value="${set('backupIntervalMinutes')}"><span>minutes</span></div>
        <div style="padding-left:23px"><label class="check"><input type="checkbox" data-setting="backupOnLaunch" ${set('backupOnLaunch') ? 'checked' : ''}><span>Au lancement de Biblijeu</span></label>
        <label class="check"><input type="checkbox" data-setting="backupOnQuit" ${set('backupOnQuit') ? 'checked' : ''}><span>À la fermeture (20 s au plus)</span></label></div></div>
      <div class="group"><div class="gtitle">Ce qui est copié</div>
        ${Object.entries(status.kinds).map(([k, v]) => `<div class="kindrow"><input type="checkbox" data-kind="${k}" ${kinds.includes(k) ? 'checked' : ''}><div class="grow"><div>${esc(v.label)} <span class="muted num">${totals[k] ? `· ${totals[k].n} dossier${totals[k].n > 1 ? 's' : ''}, ${esc(S.bytes(totals[k].bytes) || '0 o')}` : ''}</span></div><div class="help muted" style="font-size:11.5px">${esc(v.explanation)}</div></div></div>`).join('')}
        <div class="help muted" style="font-size:11.5px">Aucune ROM n'est jamais copiée : dans un dossier de ROM, seuls les fichiers de sauvegarde sont lus.</div></div>`;
    if (!b.groups.length) html += `<div class="muted">${b.isScanning ? 'Recherche des dossiers de sauvegarde…' : 'Aucun dossier de sauvegarde trouvé pour les émulateurs de ce PC.'}</div>`;
    for (const g of b.groups) {
      const on = !excluded.includes(g.emulatorID);
      const files = g.folders.reduce((s, f) => s + f.files, 0), bytes = g.folders.reduce((s, f) => s + f.bytes, 0);
      html += `<div class="list"><div class="lrow"><input type="checkbox" data-emu="${esc(g.emulatorID)}" ${on ? 'checked' : ''} title="Inclure dans la sauvegarde">
        <div class="names"><div class="t">${esc(g.name)}</div><div class="s">${files} fichier${files > 1 ? 's' : ''} · ${esc(S.bytes(bytes) || '0 o')}${g.isInstalled ? '' : ' · émulateur absent'}</div></div>
        <button class="btn" data-act="backupEmu" data-id="${esc(g.emulatorID)}" ${dest && b.available && !b.isRunning ? '' : 'disabled'}>Sauvegarder</button>
        <button class="btn" data-act="restoreEmu" data-id="${esc(g.emulatorID)}" data-name="${esc(g.name)}" ${dest && b.available && !b.isRunning ? '' : 'disabled'}>Restaurer…</button></div>
        ${g.folders.map((f) => `<div class="folderline" style="${kinds.includes(f.folder.kind) ? '' : 'opacity:.45'}"><span style="width:150px;flex:none">${esc(f.folder.title)}</span><span class="p" title="${esc(f.folder.url)}">${esc(f.folder.url.replace(/^\/(var\/)?home\/[^/]+/, '~'))}</span><span class="num">${esc(S.bytes(f.bytes) || '0 o')}</span>
          ${f.backed ? `<span title="Sur le disque : ${esc(UI.dateTime(Date.parse(f.backed.date)))}">${icon('checkCircle', 13)}</span>` : '<span style="width:13px"></span>'}
          <button class="btn plain icon" data-act="revealPath" data-path="${esc(f.folder.url)}">${icon('folder', 13)}</button></div>`).join('')}</div>`;
    }
    return html + '</div>';
  }

  // ── Tout ─────────────────────────────────────────────────────────────────

  function render() {
    if (!status) return;
    if (ui.selected && !byId(ui.selected)) ui.selected = null;
    const list = ['updates', 'backups'].includes(sel()) ? [] : S.visible(items, sel(), ui.search, set('sortOrder'), ctx());
    renderSidebar();
    renderToolbar(list);
    const active = document.activeElement;
    // Ne pas redessiner une vue pleine page pendant qu'on y tape un nombre.
    if (!(active && active.closest('#content') && active.tagName === 'INPUT' && active.type === 'number')) renderContent(list);
    renderInspector();
    showMessages();
  }

  function showMessages() {
    const text = status.errorMessage || status.infoMessage;
    if (!text || showMessages.open) return;
    showMessages.open = true;
    const isError = !!status.errorMessage;
    api.call('clearMessages');
    sheet((box, close) => {
      box.innerHTML = `<h3>${isError ? 'Erreur' : 'Biblijeu'}</h3><div class="selectable" style="white-space:pre-wrap">${esc(text)}</div><div class="hstack"><span class="grow"></span><button class="btn primary">OK</button></div>`;
      box.querySelector('button').onclick = () => { close(); showMessages.open = false; render(); };
    });
    setTimeout(() => { if (!document.querySelector('.sheet-back')) showMessages.open = false; }, 500);
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  const setSel = (s) => { ui.selected = null; status.settings.lastSelection = s; api.call('setSetting', 'lastSelection', s); render(); };
  const select = (id) => { ui.selected = id; if (!set('showInspector')) api.call('setSetting', 'showInspector', true); render(); };

  function itemMenu(it) {
    const s = st(it.id);
    const alts = it.kind === 'rom' ? emulators.filter((e) => e.systems.includes(it.systemID)) : [];
    return [
      { label: 'Jouer', disabled: !playable(it), action: () => api.call('play', it.id) },
      it.kind === 'rom' ? { label: 'Jouer depuis le début', disabled: !playable(it), action: () => api.call('play', it.id, { resumeFromStart: true }) } : null,
      ...alts.filter((e) => e !== emulatorFor(it)).map((e) => ({ label: `Jouer avec ${e.name}`, action: () => api.call('play', it.id, { emulatorID: e.id }) })),
      ...(it.discs.length > 1 ? it.discs.map((d, i) => ({ label: `Démarrer le disque ${i + 1}`, action: () => api.call('play', it.id, { disc: d }) })) : []),
      '-',
      { label: s.favorite ? 'Retirer des favoris' : 'Ajouter aux favoris', action: () => api.call('update', it.id, { favorite: !s.favorite }) },
      { label: 'Afficher dans le dossier', action: () => api.call('reveal', it.id) },
      { label: 'Copier le chemin', action: () => api.call('copyText', it.path) },
      '-',
      { label: 'Rechercher la jaquette', action: () => api.call('refetchArtwork', it.id) },
      { label: 'Corriger la jaquette…', action: () => correctArtwork(it) },
      { label: 'Choisir une image…', action: () => api.call('chooseArtwork', it.id) },
      '-',
      { label: s.hidden ? 'Afficher dans la bibliothèque' : 'Masquer de la bibliothèque', action: () => api.call('update', it.id, { hidden: !s.hidden }) },
    ];
  }

  async function onAction(a, ev) {
    const act = a.dataset.act;
    const card = a.closest('#items > [data-key]');
    const it = card ? byId(card.dataset.key) : byId(ui.selected);
    switch (act) {
      case 'play': if (it) api.call('play', it.id); break;
      case 'info': if (it) select(it.id); break;
      case 'playFromStart': if (it) api.call('play', it.id, { resumeFromStart: true }); break;
      case 'playDisc': if (it) api.call('play', it.id, { disc: it.discs[Number(a.dataset.i)] }); break;
      case 'fav': if (it) api.call('update', it.id, { favorite: !st(it.id).favorite }); break;
      case 'stateFile': if (it) api.call('chooseStateFile', it.id); break;
      case 'forgetState': if (it) api.call('update', it.id, { stateFilePath: null }); break;
      case 'reveal': if (it) api.call('reveal', it.id); break;
      case 'copyCmd': if (planCache.value && planCache.value.plan) api.call('copyText', planCache.value.plan.preview); break;
      case 'openPrefix': if (planCache.value && planCache.value.prefix) api.call('openPath', planCache.value.prefix); break;
      case 'artSearch': if (it) api.call('refetchArtwork', it.id); break;
      case 'artCorrect': if (it) correctArtwork(it); break;
      case 'artFile': if (it) api.call('chooseArtwork', it.id); break;
      case 'hide': if (it) api.call('update', it.id, { hidden: !st(it.id).hidden }); break;
      case 'addRomFolder': api.call('addRomFolder'); break;
      case 'settings': showSettings('sources'); break;
      case 'openURL': api.call('openExternal', a.dataset.url); break;
      case 'checkUpdates': api.call('checkUpdates'); break;
      case 'updateAll': api.call('updateAll'); break;
      case 'updateEmu': api.call('updateEmulator', a.dataset.id); break;
      case 'installEmu': api.call('installEmulator', a.dataset.id); break;
      case 'chooseDest': api.call('chooseBackupDestination'); break;
      case 'openDest': api.call('openPath', await api.call('backupFolderPath', '')); break;
      case 'backupNow': api.call('runBackup', 'toBackup'); break;
      case 'restoreAll': if (await api.call('confirmRestore', 'toutes les sauvegardes')) api.call('runBackup', 'toEmulator'); break;
      case 'backupEmu': api.call('runBackup', 'toBackup', a.dataset.id); break;
      case 'restoreEmu': if (await api.call('confirmRestore', a.dataset.name)) api.call('runBackup', 'toEmulator', a.dataset.id); break;
      case 'cancelBackup': api.call('cancelBackup'); break;
      case 'clearBackupMsg': api.call('clearBackupMessage'); break;
      case 'revealPath': api.call('revealPath', a.dataset.path); break;
      default: return false;
    }
    ev.stopPropagation();
    return true;
  }

  document.addEventListener('click', (ev) => {
    const a = ev.target.closest('[data-act]');
    if (a && !a.disabled) { onAction(a, ev); return; }
    const side = ev.target.closest('[data-sel]');
    if (side) { setSel(side.dataset.sel); return; }
    const card = ev.target.closest('#items > [data-key]');
    if (card) { select(card.dataset.key); return; }
    // Cliquer entre les jeux ferme le panneau.
    if (ev.target.closest('#content') && mode === 'grid') { ui.selected = null; render(); }
  });

  document.addEventListener('dblclick', (ev) => {
    const card = ev.target.closest('#items > [data-key]');
    if (card && !ev.target.closest('[data-act]')) { const it = byId(card.dataset.key); if (it && playable(it)) api.call('play', it.id); }
  });

  document.addEventListener('contextmenu', (ev) => {
    const card = ev.target.closest('#items > [data-key]');
    if (card) { ev.preventDefault(); const it = byId(card.dataset.key); if (it) menu(ev.clientX, ev.clientY, itemMenu(it)); return; }
    const side = ev.target.closest('[data-sel^="source:"]');
    if (side) {
      ev.preventDefault();
      const p = side.dataset.sel.slice(7);
      menu(ev.clientX, ev.clientY, [{ label: 'Retirer ce dossier', action: () => api.call('removeRomFolder', p) }, { label: 'Ouvrir le dossier', action: () => api.call('openPath', p) }]);
    }
  });

  // Les réglages posés directement dans les vues (panneau, mises à jour, sauvegarde).
  document.addEventListener('change', (ev) => {
    const t = ev.target;
    if (t.dataset.k && ui.selected) {
      let v = t.value || null;
      if (t.dataset.k === 'resumeSlot') v = v ? Number(v) : null;
      api.call('update', ui.selected, { [t.dataset.k]: v, ...(t.dataset.k === 'resumeSlot' && v ? { stateFilePath: null } : {}) });
    } else if (t.dataset.setting) {
      let v = t.type === 'checkbox' ? t.checked : t.type === 'number' ? Math.min(Math.max(Number(t.value) || 30, 1), 1440) : t.value;
      status.settings[t.dataset.setting] = v;
      api.call('setSetting', t.dataset.setting, v);
    } else if (t.dataset.kind) {
      const kinds = set('backupKinds').filter((k) => k !== t.dataset.kind);
      if (t.checked) kinds.push(t.dataset.kind);
      api.call('setSetting', 'backupKinds', kinds);
    } else if (t.dataset.emu) {
      const ex = set('backupExcludedEmulators').filter((k) => k !== t.dataset.emu);
      if (!t.checked) ex.push(t.dataset.emu);
      api.call('setSetting', 'backupExcludedEmulators', ex);
    }
  });

  document.addEventListener('keydown', (ev) => {
    if (document.querySelector('.sheet-back')) return;
    const typing = document.activeElement && /INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName);
    if (typing) return;
    const it = ui.selected && byId(ui.selected);
    if (ev.key === 'Enter' && it && playable(it)) { api.call('play', it.id, ev.shiftKey ? { resumeFromStart: true } : {}); ev.preventDefault(); }
    if (ev.key === 'Escape' && ui.selected) { ui.selected = null; render(); }
  });

  $('playSel').innerHTML = icon('playCircle', 19);
  $('playSel').onclick = () => { const it = byId(ui.selected); if (it) api.call('play', it.id); };
  $('options').innerHTML = icon('more', 19);
  $('options').onclick = () => menuFromButton($('options'), [
    ...S.SORTS.map((s) => ({ label: `Trier par ${s.label.toLowerCase()}`, checked: set('sortOrder') === s.id, action: () => api.call('setSetting', 'sortOrder', s.id) })),
    '-',
    { label: 'Analyser à nouveau', action: () => api.call('rescan') },
    { label: 'Rechercher les jaquettes manquantes', disabled: !items.length, action: () => api.call('fetchArtwork') },
    '-',
    { label: 'Ajouter un dossier de ROM…', action: () => api.call('addRomFolder') },
    { label: 'Ajouter une application…', action: () => api.call('addApplication') },
    '-',
    { label: 'Réglages…', action: () => showSettings('sources') },
  ]);
  $('toggleInspector').innerHTML = icon('sidebar', 18);
  $('toggleInspector').onclick = () => api.call('setSetting', 'showInspector', !set('showInspector'));
  $('searchIcon').innerHTML = icon('search', 14);
  $('searchClear').innerHTML = icon('x', 12);
  $('search').addEventListener('input', (e) => { ui.search = e.target.value; $('searchBox').classList.toggle('has-text', !!ui.search); if (['updates', 'backups'].includes(sel())) setSel('all'); else render(); });
  $('searchClear').addEventListener('click', (e) => { e.preventDefault(); $('search').value = ''; ui.search = ''; $('searchBox').classList.remove('has-text'); render(); });

  // ── Corriger la jaquette ─────────────────────────────────────────────────

  function correctArtwork(it) {
    sheet((box, close) => {
      box.innerHTML = `<h3>Corriger la jaquette</h3><div class="muted" style="font-size:12px">Cherchez sous un autre titre, puis choisissez la bonne image.</div>
        <div class="hstack"><input type="text" class="grow" id="aq"><button class="btn primary" id="as">Rechercher</button></div>
        <div id="ar" style="min-height:120px"></div><div class="hstack"><span class="grow"></span><button class="btn" id="ac">Annuler</button></div>`;
      const q = box.querySelector('#aq'), out = box.querySelector('#ar');
      q.value = st(it.id).searchTitle || it.title;
      const search = async () => {
        out.innerHTML = '<div class="hstack muted" style="justify-content:center;padding:30px"><span class="spinner"></span>Recherche…</div>';
        const list = await api.call('artworkCandidates', it.id, q.value);
        if (!list.length) { out.innerHTML = `<div class="muted" style="text-align:center;padding:30px">Aucune image trouvée.${status.settings.steamGridDBKey ? '' : ' Une clé SteamGridDB (Réglages → Jaquettes) élargit la recherche.'}</div>`; return; }
        out.innerHTML = `<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));gap:10px;max-height:380px;overflow:auto">${list.map((c, i) => `
          <div data-i="${i}" style="cursor:pointer" title="${esc(c.title)} — ${esc(c.source)}"><div class="cover" style="--cover-aspect:3/4"><img class="art" src="${esc(c.imageURL)}" style="object-fit:contain;background:#000"></div><div class="muted" style="font-size:10.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(c.source)} · ${esc(c.title)}</div></div>`).join('')}</div>`;
        out.querySelectorAll('[data-i]').forEach((n) => { n.onclick = () => { api.call('applyArtwork', it.id, list[Number(n.dataset.i)].imageURL, q.value); close(); }; });
      };
      box.querySelector('#as').onclick = search;
      q.addEventListener('keydown', (e) => { if (e.key === 'Enter') search(); });
      box.querySelector('#ac').onclick = close;
      search();
    }, { width: 620 });
  }

  // ── Réglages ─────────────────────────────────────────────────────────────

  function showSettings(tab) {
    sheet((box, close) => {
      let current = tab;
      const draw = () => {
        const s = status.settings;
        const check = (k, label, help) => `<label class="check"><input type="checkbox" data-s="${k}" ${s[k] ? 'checked' : ''}><span>${esc(label)}${help ? `<div class="help">${esc(help)}</div>` : ''}</span></label>`;
        const paths = (list, removeAct) => `<div class="pathlist">${list.length ? list.map((p) => `<div class="row">${icon('folder', 13)}<span class="p" title="${esc(p)}">${esc(p)}</span><button class="btn plain icon" data-a="${removeAct}" data-p="${esc(p)}" title="Retirer">${icon('minus', 13)}</button></div>`).join('') : '<div class="muted">Aucun.</div>'}</div>`;
        let body = '';
        if (current === 'sources') {
          body = `<div class="group"><div class="gtitle">Dossiers de ROM</div>${paths(s.romFolders, 'rmRom')}<div><button class="btn" data-a="addRom">Ajouter…</button></div></div>
            <div class="group"><div class="gtitle">Dossiers exclus</div><div class="help">Laissés de côté par l'analyse et la surveillance (téléchargements en cours, dossiers de travail…).</div>${paths(s.excludedFolders, 'rmExcl')}<div><button class="btn" data-a="addExcl">Ajouter…</button></div></div>
            <div class="group"><div class="gtitle">Dossiers d'émulateurs et d'AppImage</div><div class="help">Cherchés sur trois niveaux, en plus des Flatpak et des paquets installés : « Emulateurs/Playstation 3/rpcs3.AppImage » est trouvé.</div>${paths(s.applicationFolders, 'rmApp')}<div><button class="btn" data-a="addApp">Ajouter…</button></div></div>
            <div class="group">${check('scanSteam', 'Inclure les jeux Steam', 'Les jeux installés et ceux ajoutés à Steam à la main ; ils se lancent par Steam.')}
              ${check('scanApplications', 'Inclure les jeux et lanceurs installés', 'Ceux du menu des applications (Flatpak compris) qui se déclarent comme jeux.')}
              ${check('watchFolders', 'Surveiller les dossiers', 'Un jeu copié dans un dossier, ou installé par Steam, apparaît tout seul.')}
              ${s.manualApplications.length ? `<div class="gtitle" style="margin-top:6px">Ajoutés à la main</div>${paths(s.manualApplications, 'rmManual')}` : ''}</div>`;
        } else if (current === 'launch') {
          body = `<div class="group">${check('directLaunch', 'Lancement direct', "Plein écran et sans l'interface de l'émulateur, quand il l'accepte (Dolphin, DuckStation, PCSX2…).")}
              ${check('resumeOnLaunch', "Reprendre la sauvegarde d'état au lancement", "Quand l'émulateur sait le faire en ligne de commande (DuckStation, PCSX2).")}</div>
            <div class="group"><div class="gtitle">Jeux Windows : Proton</div>
              ${status.protons.length ? `<select data-s="protonVersion"><option value="">Automatique (${esc(status.protons[0])})</option>${status.protons.map((p) => `<option ${s.protonVersion === p ? 'selected' : ''}>${esc(p)}</option>`).join('')}</select>` : '<div class="muted">Aucun Proton trouvé : installez « Proton Experimental » depuis Steam.</div>'}
              <div class="help">Les Proton que Steam a installés (bibliothèques Steam et compatibilitytools.d). ${status.hasUmu ? 'Lancés par umu-run, dans le conteneur Steam Linux Runtime, comme le fait Steam.' : 'umu-run est introuvable : Proton est lancé directement.'} Les jeux Steam, eux, utilisent le Proton choisi dans Steam.</div>
              <div class="hstack"><span class="muted grow" style="font-size:11.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">Préfixes : ${esc(s.prefixesFolder)}</span><button class="btn" data-a="openPrefixes">Ouvrir</button></div></div>
            <div class="group"><div class="gtitle">Émulateur par console</div>${S.SYSTEMS.filter((x) => emulators.some((e) => e.systems.includes(x.id)) && x.id !== 'windows').map((x) => {
              const alts = emulators.filter((e) => e.systems.includes(x.id));
              return `<div class="hstack"><span class="grow">${esc(x.name)}</span><select data-emusys="${x.id}"><option value="">Automatique</option>${alts.map((e) => `<option value="${e.id}" ${s.emulatorForSystem[x.id] === e.id ? 'selected' : ''}>${esc(e.name)}</option>`).join('')}</select></div>`;
            }).join('') || '<div class="muted">Aucun émulateur installé.</div>'}</div>
            <div class="group"><div><button class="btn" data-a="clearHistory">Effacer l'historique de jeu</button></div></div>`;
        } else if (current === 'artwork') {
          body = `<div class="group">${check('autoFetchArtwork', "Rechercher les jaquettes après l'analyse")}
              <div class="hstack"><span class="grow">Région préférée</span><select data-s="preferredRegion">${['Europe', 'France', 'États-Unis', 'Japon', 'Monde'].map((r) => `<option ${s.preferredRegion === r ? 'selected' : ''}>${r}</option>`).join('')}</select></div>
              <div class="hstack"><span class="grow">Taille des vignettes</span><input type="range" min="120" max="260" step="4" data-s="cardSize" value="${s.cardSize}"></div></div>
            <div class="group"><div class="gtitle">Clé SteamGridDB</div>
              <input type="password" data-s="steamGridDBKey" value="${esc(s.steamGridDBKey)}" placeholder="Collez votre clé ici">
              <div class="help">Gratuite : créez un compte sur steamgriddb.com, puis Preferences → API → Generate API key. Elle couvre ce que l'archive libretro n'a pas : Switch, jeux PC.</div>
              <div class="hstack"><button class="btn" data-a="testKey">Tester la clé</button><button class="linkbtn" data-a="getKey">Obtenir une clé</button><span id="keyStatus"></span></div></div>
            <div class="group"><div class="hstack"><button class="btn" data-a="fetchArt">Rechercher les jaquettes manquantes</button><button class="btn" data-a="clearArt">Tout rechercher à nouveau</button></div></div>`;
        } else {
          body = `<div class="group"><div class="gtitle">Mises à jour de Biblijeu</div>
              <label class="check"><input type="checkbox" data-a="autoUpdate" ${status.autoUpdate ? 'checked' : ''}><span>Rechercher automatiquement les mises à jour</span></label>
              <div class="hstack"><button class="btn" data-a="checkApp">Rechercher maintenant</button><span class="muted">Version ${esc(status.version)}</span></div></div>`;
        }
        box.innerHTML = `<div class="hstack"><h3 class="grow">Réglages</h3><button class="btn plain icon" data-a="close">${icon('x', 14)}</button></div>
          <div class="tabs">${[['sources', 'Sources'], ['launch', 'Lancement'], ['artwork', 'Jaquettes'], ['app', 'Application']].map(([id, l]) => `<button data-tab="${id}" class="${current === id ? 'on' : ''}">${l}</button>`).join('')}</div>${body}`;
        box.querySelectorAll('[data-tab]').forEach((b) => { b.onclick = () => { current = b.dataset.tab; draw(); }; });
        box.querySelectorAll('[data-s]').forEach((inp) => {
          const k = inp.dataset.s;
          inp.addEventListener(inp.type === 'checkbox' || inp.tagName === 'SELECT' || inp.type === 'range' ? 'change' : 'input', () => {
            const v = inp.type === 'checkbox' ? inp.checked : inp.type === 'range' ? Number(inp.value) : inp.value;
            status.settings[k] = v;
            api.call('setSetting', k, v);
          });
        });
        box.querySelectorAll('[data-emusys]').forEach((sel2) => sel2.addEventListener('change', () => {
          const m = { ...status.settings.emulatorForSystem };
          if (sel2.value) m[sel2.dataset.emusys] = sel2.value; else delete m[sel2.dataset.emusys];
          status.settings.emulatorForSystem = m;
          api.call('setSetting', 'emulatorForSystem', m);
        }));
        box.querySelectorAll('[data-a]').forEach((b) => {
          const handler = async () => {
            const p = b.dataset.p;
            const later = () => setTimeout(draw, 400);
            switch (b.dataset.a) {
              case 'close': close(); break;
              case 'addRom': await api.call('addRomFolder'); later(); break;
              case 'rmRom': await api.call('removeRomFolder', p); later(); break;
              case 'addExcl': await api.call('addExcludedFolder'); later(); break;
              case 'rmExcl': await api.call('removeExcludedFolder', p); later(); break;
              case 'addApp': await api.call('addApplicationFolder'); later(); break;
              case 'rmApp': await api.call('removeApplicationFolder', p); later(); break;
              case 'rmManual': await api.call('removeManualApplication', p); later(); break;
              case 'openPrefixes': api.call('openPath', status.settings.prefixesFolder); break;
              case 'clearHistory': api.call('clearHistory'); break;
              case 'testKey': { const ks = box.querySelector('#keyStatus'); ks.innerHTML = '<span class="spinner"></span>'; const ok = await api.call('testSGDBKey'); ks.innerHTML = ok ? '<span style="color:var(--ok)">Clé valide</span>' : '<span style="color:var(--warm)">Clé refusée</span>'; break; }
              case 'getKey': api.call('openExternal', 'https://www.steamgriddb.com/profile/preferences/api'); break;
              case 'fetchArt': api.call('fetchArtwork'); break;
              case 'clearArt': api.call('clearArtworkCache'); break;
              case 'autoUpdate': api.call('setAutoUpdate', b.checked); break;
              case 'checkApp': api.call('checkAppUpdates'); break;
              default:
            }
          };
          b.addEventListener(b.type === 'checkbox' ? 'change' : 'click', handler);
        });
      };
      draw();
    }, { width: 620 });
  }

  // ── Messages du processus principal ──────────────────────────────────────

  api.on('state', (msg) => {
    if (msg.items) { items = msg.items; emulators = msg.emulators; }
    if (msg.states) states = msg.states;
    if (msg.status) status = msg.status;
    render();
  });
  api.on('focusSearch', () => { $('search').focus(); $('search').select(); });
  api.on('toggleInspector', () => api.call('setSetting', 'showInspector', !set('showInspector')));
  api.on('showSettings', () => showSettings('sources'));
  api.on('quitting', () => {
    document.body.appendChild(h(`<div class="sheet-back"><div class="sheet" style="width:360px"><div class="hstack"><span class="spinner"></span><b>Sauvegarde avant de quitter…</b></div><div class="muted" style="font-size:12px">20 secondes au plus.</div></div></div>`));
  });
  api.call('ready');
}());
