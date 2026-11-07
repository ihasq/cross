(() => {
  const root = document.documentElement;
  const body = document.body;
  const themeToggle = document.querySelector(".theme-toggle");
  const menuToggle = document.querySelector(".menu-toggle");
  const sidebarScrim = document.querySelector(".sidebar-scrim");
  const sideLinks = [...document.querySelectorAll(".side-link")];
  const sections = [...document.querySelectorAll(".doc-section[id]")];
  const toast = document.querySelector(".toast");
  let toastTimer;

  const preferredTheme = localStorage.getItem("cross-theme") ||
    (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  setTheme(preferredTheme);

  function setTheme(theme) {
    root.dataset.theme = theme;
    themeToggle?.setAttribute("aria-label", theme === "dark" ? "Use light theme" : "Use dark theme");
  }

  themeToggle?.addEventListener("click", () => {
    const next = root.dataset.theme === "dark" ? "light" : "dark";
    setTheme(next);
    localStorage.setItem("cross-theme", next);
  });

  function closeNav() {
    body.classList.remove("nav-open");
    menuToggle?.setAttribute("aria-expanded", "false");
  }

  menuToggle?.addEventListener("click", () => {
    const open = body.classList.toggle("nav-open");
    menuToggle.setAttribute("aria-expanded", String(open));
  });
  sidebarScrim?.addEventListener("click", closeNav);
  sideLinks.forEach((link) => link.addEventListener("click", closeNav));

  const activeObserver = new IntersectionObserver((entries) => {
    const visible = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
    if (!visible) return;
    sideLinks.forEach((link) => {
      const current = link.getAttribute("href") === `#${visible.target.id}`;
      link.classList.toggle("active", current);
      if (current) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
  }, { rootMargin: "-18% 0px -62%", threshold: [0, 0.1, 0.5] });
  sections.forEach((section) => activeObserver.observe(section));

  function showToast(message = "Copied to clipboard") {
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 1600);
  }

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const value = button.dataset.copy;
      try {
        await navigator.clipboard.writeText(value);
      } catch {
        const area = document.createElement("textarea");
        area.value = value;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        document.execCommand("copy");
        area.remove();
      }
      const label = button.querySelector("span");
      const previous = label?.textContent;
      button.classList.add("copied");
      if (label) label.textContent = "Copied";
      showToast();
      setTimeout(() => {
        button.classList.remove("copied");
        if (label) label.textContent = previous;
      }, 1400);
    });
  });

  document.querySelectorAll("[data-tabs]").forEach((tabs) => {
    const buttons = [...tabs.querySelectorAll('[role="tab"]')];
    const panels = [...tabs.querySelectorAll('[role="tabpanel"]')];
    buttons.forEach((button, index) => {
      button.addEventListener("click", () => activateTab(index));
      button.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        let next = index;
        if (event.key === "ArrowLeft") next = (index - 1 + buttons.length) % buttons.length;
        if (event.key === "ArrowRight") next = (index + 1) % buttons.length;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = buttons.length - 1;
        activateTab(next);
        buttons[next].focus();
      });
    });

    function activateTab(index) {
      buttons.forEach((button, i) => {
        button.setAttribute("aria-selected", String(i === index));
        button.tabIndex = i === index ? 0 : -1;
      });
      panels.forEach((panel, i) => { panel.hidden = i !== index; });
    }
  });

  document.querySelectorAll("[data-accordion] article").forEach((item) => {
    const button = item.querySelector("button");
    const panel = item.querySelector(".accordion-panel");
    button.addEventListener("click", () => {
      const expanded = button.getAttribute("aria-expanded") === "true";
      button.setAttribute("aria-expanded", String(!expanded));
      panel.hidden = expanded;
    });
  });

  const searchDialog = document.querySelector(".search-dialog");
  const searchInput = searchDialog.querySelector("input");
  const searchResults = searchDialog.querySelector(".search-results");
  const searchEntries = sections.map((section) => ({
    id: section.id,
    title: section.dataset.title || section.querySelector("h2, h1")?.textContent.trim(),
    text: section.textContent.replace(/\s+/g, " ").trim().toLowerCase(),
  }));

  function openSearch() {
    if (!searchDialog.open) searchDialog.showModal();
    searchInput.value = "";
    renderSearch("");
    requestAnimationFrame(() => searchInput.focus());
  }

  function closeSearch() {
    if (searchDialog.open) searchDialog.close();
  }

  document.querySelector(".search-trigger")?.addEventListener("click", openSearch);
  document.querySelector(".search-close")?.addEventListener("click", closeSearch);
  searchDialog.addEventListener("click", (event) => {
    if (event.target === searchDialog) closeSearch();
  });
  document.addEventListener("keydown", (event) => {
    const typing = ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName);
    if (event.key === "/" && !typing && !searchDialog.open) {
      event.preventDefault();
      openSearch();
    }
  });

  function renderSearch(query) {
    const normalized = query.trim().toLowerCase();
    if (!normalized) {
      searchResults.innerHTML = '<p class="search-hint">Try “install”, “service”, “apk”, or “security”.</p>';
      return;
    }
    const tokens = normalized.split(/\s+/);
    const matches = searchEntries.filter((entry) => tokens.every((token) => entry.text.includes(token))).slice(0, 8);
    if (!matches.length) {
      searchResults.innerHTML = '<p class="search-empty">No matching section. Try a shorter term.</p>';
      return;
    }
    searchResults.replaceChildren(...matches.map((entry) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "search-result";
      button.setAttribute("role", "option");
      button.innerHTML = `<span><strong>${entry.title}</strong><small>#${entry.id}</small></span><span aria-hidden="true">↵</span>`;
      button.addEventListener("click", () => {
        closeSearch();
        document.getElementById(entry.id)?.scrollIntoView({ behavior: "smooth" });
      });
      return button;
    }));
  }
  searchInput.addEventListener("input", () => renderSearch(searchInput.value));

  window.addEventListener("resize", () => {
    if (innerWidth > 760) closeNav();
  });
})();
