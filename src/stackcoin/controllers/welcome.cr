class Welcome < Application
  base "/"

  def index
    welcome_text = "You're being trampled by Spider-Gazelle!"

    respond_with do
      # html template("welcome.ecr")
      json({welcome: welcome_text})
    end
  end
end
