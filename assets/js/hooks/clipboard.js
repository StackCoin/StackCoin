const Clipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboardText
      if (text) {
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.innerText
          this.el.innerText = "Copied!"
          setTimeout(() => { this.el.innerText = original }, 1500)
        })
      }
    })
  }
}

export default Clipboard
