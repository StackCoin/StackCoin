const NetworkGraph = {
  async mounted() {
    const d3 = await import("d3")
    this.d3 = d3

    const container = this.el
    const compact = container.dataset.compact === "true"

    // Scroll the graph into view on the full /network page
    if (!compact) {
      container.scrollIntoView({ behavior: "smooth", block: "start" })
    }

    const raw = container.dataset.graph
    if (!raw) return

    const data = JSON.parse(raw)
    this.showReserve = false
    this.fullData = data
    this.compact = compact

    this.render(data, compact)

    // Listen for toggle events from LiveView
    this.handleEvent("toggle_reserve", ({ show }) => {
      this.showReserve = show
      this.render(this.fullData, this.compact)
    })
  },

  updated() {
    const raw = this.el.dataset.graph
    if (!raw) return

    const data = JSON.parse(raw)
    this.fullData = data
    this.render(data, this.compact)
  },

  render(data, compact) {
    const d3 = this.d3
    const container = this.el

    // Clear previous
    d3.select(container).select("svg").remove()

    // Filter reserve if toggle is off
    let nodes = data.nodes
    let links = data.links

    if (!this.showReserve) {
      const reserveId = 1
      nodes = nodes.filter(n => n.id !== reserveId)
      const nodeIds = new Set(nodes.map(n => n.id))
      links = links.filter(l => nodeIds.has(l.source) && nodeIds.has(l.target))
    }

    if (nodes.length === 0) return

    const width = container.clientWidth
    const height = compact ? 400 : Math.max(600, window.innerHeight - 200)

    const svg = d3.select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height])

    // Zoom (full mode only)
    if (!compact) {
      const g = svg.append("g")
      svg.call(d3.zoom()
        .scaleExtent([0.3, 5])
        .on("zoom", (event) => g.attr("transform", event.transform)))
      this.g = g
    } else {
      this.g = svg.append("g")
    }
    const g = this.g

    // Scales
    const maxBalance = d3.max(nodes, d => d.balance) || 1
    const radiusScale = d3.scaleSqrt()
      .domain([0, maxBalance])
      .range([4, compact ? 20 : 35])

    const maxVolume = d3.max(links, d => d.volume) || 1
    const strokeScale = d3.scaleLog()
      .domain([1, maxVolume])
      .range([0.5, compact ? 4 : 8])

    // Simulation
    const simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(compact ? 60 : 100))
      .force("charge", d3.forceManyBody().strength(compact ? -100 : -200))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(d => radiusScale(d.balance) + 2))

    // Links
    const link = g.append("g")
      .selectAll("line")
      .data(links)
      .join("line")
      .attr("stroke", "#d1d5db")
      .attr("stroke-width", d => strokeScale(Math.max(1, d.volume)))

    // Nodes
    const node = g.append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .style("cursor", "pointer")

    node.append("circle")
      .attr("r", d => radiusScale(d.balance))
      .attr("fill", d => d.is_bot ? "#f3f4f6" : "#fff")
      .attr("stroke", d => d.is_bot ? "#9ca3af" : "#000")
      .attr("stroke-width", 1.5)

    // Labels
    if (!compact || nodes.length < 30) {
      node.append("text")
        .text(d => d.username)
        .attr("text-anchor", "middle")
        .attr("dy", d => radiusScale(d.balance) + 14)
        .attr("font-size", compact ? "9px" : "11px")
        .attr("fill", "#6b7280")
        .attr("font-family", "system-ui, sans-serif")
    }

    // Tooltip
    node.append("title")
      .text(d => `${d.username}: ${d.balance} STK`)

    // Click to navigate
    const liveSocket = window.liveSocket
    node.on("click", (event, d) => {
      liveSocket.redirect(`/user/${d.id}`)
    })

    // Drag (full mode only)
    if (!compact) {
      node.call(d3.drag()
        .on("start", (event, d) => {
          if (!event.active) simulation.alphaTarget(0.3).restart()
          d.fx = d.x
          d.fy = d.y
        })
        .on("drag", (event, d) => {
          d.fx = event.x
          d.fy = event.y
        })
        .on("end", (event, d) => {
          if (!event.active) simulation.alphaTarget(0)
          d.fx = null
          d.fy = null
        }))
    }

    // Tick
    simulation.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)

      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
  }
}

export default NetworkGraph
