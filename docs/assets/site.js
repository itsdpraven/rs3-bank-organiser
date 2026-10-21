// The animated bank on the front page: acts out what the plugin shows on the
// real bank (green = drag, yellow = drop here), with the same banner wording.
// It's an illustration: the real plugin draws on the game's own bank window.
(function () {
  "use strict";

  var bank = document.getElementById("demo");
  if (!bank) return;
  var banner = document.getElementById("demo-banner");
  var grid = bank.querySelector(".bank-grid");
  var overlay = document.createElement("div");
  overlay.className = "overlay";
  overlay.setAttribute("aria-hidden", "true");
  bank.appendChild(overlay);

  var slots = Array.prototype.slice.call(grid.querySelectorAll(".slot"));
  function slot(name) {
    for (var i = 0; i < slots.length; i++) if (slots[i].dataset.item === name) return slots[i];
    return null;
  }
  function tab(name) { return bank.querySelector('.tab[data-tab="' + name + '"]'); }

  var NAMES = {
    rocktail: "Rocktail", overload: "Overload (4)", prayer: "Prayer potion (4)", restore: "Super restore (4)",
    magiclogs: "Magic logs", maplelogs: "Maple logs", hammer: "Hammer", whip: "Abyssal whip"
  };

  // Positions relative to the demo window.
  function rectOf(el) {
    var b = bank.getBoundingClientRect(), r = el.getBoundingClientRect();
    return { x: r.left - b.left, y: r.top - b.top, w: r.width, h: r.height };
  }
  function box(cls, r, grow) {
    var d = document.createElement("div");
    d.className = cls;
    grow = grow || 0;
    d.style.left = (r.x - grow) + "px";
    d.style.top = (r.y - grow) + "px";
    d.style.width = (r.w + 2 * grow) + "px";
    d.style.height = (r.h + 2 * grow) + "px";
    overlay.appendChild(d);
    return d;
  }
  function tag(text, cls, r, below) {
    var t = document.createElement("div");
    t.className = "tag " + cls;
    t.textContent = text;
    t.style.left = (r.x + r.w / 2) + "px";
    t.style.top = below ? (r.y + r.h + 6) + "px" : (r.y - 24) + "px";
    overlay.appendChild(t);
  }
  function trail(a, b) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "trail");
    var line = document.createElementNS(ns, "line");
    line.setAttribute("x1", a.x + a.w / 2); line.setAttribute("y1", a.y + a.h / 2);
    line.setAttribute("x2", b.x + b.w / 2); line.setAttribute("y2", b.y + b.h / 2);
    svg.appendChild(line);
    overlay.insertBefore(svg, overlay.firstChild);
  }

  // What's shown now: { text, greens: [item names], drop: element, tip: { item, text } }.
  var shown = null;
  function draw(state) {
    shown = state;
    overlay.innerHTML = "";
    if (!state) return;
    banner.textContent = state.text;
    banner.classList.remove("ok");
    var greens = state.greens || [];
    var single = greens.length === 1;
    var first = null;
    greens.forEach(function (name, i) {
      var r = rectOf(slot(name));
      if (i === 0) first = r;
      var h = box("hl", r);
      if (!single) {
        var n = document.createElement("b");
        n.textContent = i + 1;
        h.appendChild(n);
      }
    });
    if (state.drop) {
      var d = rectOf(state.drop);
      box("drop", d, 3);
      tag("Drop here", "dropping", { x: d.x - 3, y: d.y - 3, w: d.w + 6, h: d.h + 6 }, true);
      if (single && first) {
        trail(first, d);
        tag("Drag", "drag", first, false);
      }
    }
    if (state.tip) {
      var s = rectOf(slot(state.tip.item));
      var t = document.createElement("div");
      t.className = "tip";
      t.textContent = state.tip.text;
      t.style.top = (s.y - 32) + "px";
      overlay.appendChild(t);
      // Centred over the item, but kept inside the window.
      var width = t.offsetWidth, room = bank.clientWidth;
      t.style.left = Math.max(6, Math.min(s.x + s.w / 2 - width / 2, room - width - 6)) + "px";
    }
  }
  function flash(text) {
    banner.textContent = text;
    banner.classList.add("ok");
  }

  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var running = true, generation = 0;
  function sleep(ms) {
    var mine = generation;
    return new Promise(function (resolve, reject) {
      setTimeout(function () { mine === generation ? resolve() : reject("stopped"); }, ms);
    });
  }
  async function waitWhileHidden() {
    while (!running) await sleep(300);
  }

  // An item flies from its slot to the tab, the way the player drags it.
  async function drag(name, target) {
    var from = slot(name), r = rectOf(from), to = rectOf(target);
    var fly = document.createElement("div");
    fly.className = "flyer";
    fly.style.left = r.x + "px"; fly.style.top = r.y + "px";
    fly.style.width = r.w + "px"; fly.style.height = r.h + "px";
    fly.innerHTML = from.innerHTML;
    bank.appendChild(fly);
    from.classList.add("gone");
    overlay.innerHTML = "";
    fly.getBoundingClientRect(); // start the transition from here
    var dx = to.x + to.w / 2 - (r.x + r.w / 2), dy = to.y + to.h / 2 - (r.y + r.h / 2);
    fly.style.transform = "translate(" + dx + "px," + dy + "px) scale(0.55)";
    fly.style.opacity = "0.15";
    await sleep(800);
    fly.remove();
  }

  function reset() {
    slots.forEach(function (s) { s.classList.remove("gone"); });
    var gathering = tab("5");
    gathering.classList.remove("shown");
    bank.querySelectorAll(".tab .badge").forEach(function (b) {
      b.classList.toggle("tidy", b.dataset.start === "tidy");
    });
  }

  async function play() {
    var food = ["rocktail", "overload", "prayer", "restore"];
    var foodTab = tab("3"), plus = tab("plus"), gathering = tab("5");
    for (;;) {
      reset();
      // 1. Four items into the Food & potions tab, in number order.
      var left = food.slice();
      while (left.length) {
        draw({ text: "Drag the " + left.length + " green item" + (left.length > 1 ? "s" : "")
          + " onto tab 3 (Food & potions), in number order", greens: left, drop: foodTab });
        await sleep(1700);
        await waitWhileHidden();
        var name = left.shift();
        await drag(name, foodTab);
        flash(NAMES[name] + " is in the right tab" + (left.length ? " - " + left.length + " to go" : ""));
        await sleep(left.length ? 700 : 1300);
      }
      foodTab.querySelector(".badge").classList.add("tidy");
      // 2. A new tab: the first item onto "+", then the rest onto the new tab.
      draw({ text: "New Gathering tab: drag item 1 (Magic logs) onto the yellow +",
        greens: ["magiclogs", "maplelogs"], drop: plus });
      await sleep(2300);
      await waitWhileHidden();
      await drag("magiclogs", plus);
      gathering.classList.add("shown");
      flash("Magic logs is in the right tab - 1 to go");
      await sleep(900);
      draw({ text: "Drag the 1 green item onto tab 5 (Gathering), in number order",
        greens: ["maplelogs"], drop: gathering });
      await sleep(2200);
      await waitWhileHidden();
      await drag("maplelogs", gathering);
      gathering.querySelector(".badge").classList.add("tidy");
      flash("Maple logs is in the right tab");
      await sleep(1300);
      // 3. Pointing at an item says where it goes.
      draw({ text: "Point at any item to see where it goes", tip: { item: "hammer", text: "Goes in tab 1: Teleports & tools" } });
      await sleep(2200);
      draw({ text: "Point at any item to see where it goes", tip: { item: "whip", text: "Goes in tab 2: Melee" } });
      await sleep(2200);
      draw(null);
      banner.textContent = "Every item in the right tab, every tab in order";
      await sleep(2000);
    }
  }

  window.addEventListener("resize", function () { if (shown) draw(shown); });

  if (reduced) {
    // A still picture of the first step.
    draw({ text: "Drag the 4 green items onto tab 3 (Food & potions), in number order",
      greens: ["rocktail", "overload", "prayer", "restore"], drop: tab("3") });
    return;
  }
  // Only animate while the demo is on screen and the page is visible.
  var onScreen = true;
  function update() { running = onScreen && !document.hidden; }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      onScreen = entries[0].isIntersecting;
      update();
    }).observe(bank);
  }
  document.addEventListener("visibilitychange", update);
  function start() {
    generation++;
    play().catch(function () {});
  }
  if (document.readyState === "complete") start();
  else window.addEventListener("load", start);
})();
