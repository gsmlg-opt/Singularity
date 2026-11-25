export const SourceAutocomplete = {
  mounted() {
    const input = this.el.querySelector('[role="combobox"]')
    const value = this.el.querySelector('input[type="hidden"]')
    const list = this.el.querySelector('[role="listbox"]')
    const options = Array.from(list.children, element => ({
      element,
      label: element.textContent.trim(),
      slug: element.dataset.value,
    }))

    let matches = []
    let active = -1
    let selected = options.find(option => option.slug === value.value)

    const highlight = index => {
      matches[active]?.element.classList.remove("highlighted")
      active = index
      const option = matches[active]?.element
      if (option) {
        input.setAttribute("aria-activedescendant", option.id)
        option.classList.add("highlighted")
        option.scrollIntoView({block: "nearest"})
      } else {
        input.removeAttribute("aria-activedescendant")
      }
    }

    const show = open => {
      list.hidden = !open
      input.setAttribute("aria-expanded", String(open))
      this.el.classList.toggle("autocomplete-open", open)
    }

    const filter = query => {
      highlight(-1)
      matches = options.filter(option => {
        const match = option.label.toLowerCase().includes(query) || option.slug.includes(query)
        option.element.hidden = !match
        return match
      })
      list.scrollTop = 0
      show(matches.length > 0)
    }

    const select = option => {
      selected?.element.setAttribute("aria-selected", "false")
      selected = option
      selected?.element.setAttribute("aria-selected", "true")
      value.value = option?.slug ?? input.value
    }

    const commit = option => {
      select(option)
      if (option) input.value = option.label
      highlight(-1)
      show(false)
      value.dispatchEvent(new Event("input", {bubbles: true}))
    }

    input.addEventListener("focus", () => filter(""))
    input.addEventListener("click", () => { if (list.hidden) filter("") })
    input.addEventListener("input", event => {
      event.stopPropagation()
      const query = input.value.trim().toLowerCase()
      select(options.find(option => option.slug === query || option.label.toLowerCase() === query))
      filter(query)
    })
    input.addEventListener("change", event => event.stopPropagation())
    input.addEventListener("blur", () => {
      if (selected) input.value = selected.label
      highlight(-1)
      show(false)
    })
    input.addEventListener("keydown", event => {
      if (event.isComposing) return
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        if (list.hidden) filter(input.value.trim().toLowerCase())
        if (!matches.length) return
        const next = active === -1 && event.key === "ArrowUp"
          ? matches.length - 1
          : active + (event.key === "ArrowDown" ? 1 : -1)
        highlight(Math.max(0, Math.min(next, matches.length - 1)))
      } else if (!list.hidden && event.key === "Escape") {
        event.preventDefault()
        highlight(-1)
        show(false)
      } else if (!list.hidden && event.key === "Enter" && active >= 0) {
        event.preventDefault()
        commit(matches[active])
      }
    })

    list.addEventListener("pointerdown", event => {
      if (event.target.closest('[role="option"]')) {
        event.preventDefault()
      }
    })
    list.addEventListener("click", event => {
      const element = event.target.closest('[role="option"]')
      const option = matches.find(option => option.element === element)
      if (option) commit(option)
    })
  },
}

export const TrendingInterval = {
  mounted() {
    const form = this.el
    const defaults = JSON.parse(form.dataset.intervals)
    const range = form.querySelector("#config-since")
    const interval = form.querySelector("#source-interval")
    let followsRange = interval.value === String(defaults[range.value])

    interval.addEventListener("input", () => { followsRange = interval.value === "" })
    range.addEventListener("change", () => {
      if (followsRange) interval.value = String(defaults[range.value])
    })
  },
}
