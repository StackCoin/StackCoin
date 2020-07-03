class Root < Application
  base "/"

  def index
    respond_with do
      html template("home.ecr")
      json(nil) # TODO root
    end
  end
end
