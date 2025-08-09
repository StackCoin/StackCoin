defmodule StackCoinWeb.Schemas do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule User do
    OpenApiSpex.schema(%{
      title: "User",
      description: "A StackCoin user",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "User ID"},
        username: %Schema{type: :string, description: "Username"},
        balance: %Schema{type: :integer, description: "User's STK balance"},
        admin: %Schema{type: :boolean, description: "Whether user is an admin"},
        banned: %Schema{type: :boolean, description: "Whether user is banned"},
        inserted_at: %Schema{
          type: :string,
          description: "Creation timestamp",
          format: :"date-time"
        },
        updated_at: %Schema{type: :string, description: "Update timestamp", format: :"date-time"}
      },
      required: [:username, :balance, :admin, :banned],
      example: %{
        "id" => 123,
        "username" => "johndoe",
        "balance" => 1000,
        "admin" => false,
        "banned" => false,
        "inserted_at" => "2019-09-12T12:34:55Z",
        "updated_at" => "2025-09-13T10:11:12Z"
      }
    })
  end

  defmodule UserResponse do
    OpenApiSpex.schema(%{
      title: "UserResponse",
      description: "Response schema for single user",
      type: :object,
      properties: %{
        data: User
      },
      example: %{
        "data" => %{
          "id" => 123,
          "username" => "johndoe",
          "balance" => 1000,
          "admin" => false,
          "banned" => false,
          "inserted_at" => "2019-09-12T12:34:55Z",
          "updated_at" => "2025-09-13T10:11:12Z"
        }
      },
      "x-struct": __MODULE__
    })
  end

  defmodule UsersResponse do
    OpenApiSpex.schema(%{
      title: "UsersResponse",
      description: "Response schema for multiple users",
      type: :object,
      properties: %{
        users: %Schema{description: "The users list", type: :array, items: User},
        pagination: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer, description: "Current page"},
            limit: %Schema{type: :integer, description: "Items per page"},
            total: %Schema{type: :integer, description: "Total items"},
            total_pages: %Schema{type: :integer, description: "Total pages"}
          }
        }
      },
      example: %{
        "users" => [
          %{
            "id" => 123,
            "username" => "johndoe",
            "balance" => 1000,
            "admin" => false,
            "banned" => false
          },
          %{
            "id" => 456,
            "username" => "janedoe",
            "balance" => 500,
            "admin" => true,
            "banned" => false
          }
        ],
        "pagination" => %{
          "page" => 1,
          "limit" => 20,
          "total" => 2,
          "total_pages" => 1
        }
      }
    })
  end

  defmodule BalanceResponse do
    OpenApiSpex.schema(%{
      title: "BalanceResponse",
      description: "Response schema for user balance",
      type: :object,
      properties: %{
        balance: %Schema{type: :integer, description: "User's STK balance"},
        username: %Schema{type: :string, description: "Username"}
      },
      required: [:balance, :username],
      example: %{
        "balance" => 1000,
        "username" => "johndoe"
      }
    })
  end

  defmodule Transaction do
    OpenApiSpex.schema(%{
      title: "Transaction",
      description: "A STK transaction",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Transaction ID"},
        from: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "From user ID"},
            username: %Schema{type: :string, description: "From username"}
          }
        },
        to: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "To user ID"},
            username: %Schema{type: :string, description: "To username"}
          }
        },
        amount: %Schema{type: :integer, description: "Transaction amount"},
        time: %Schema{type: :string, description: "Transaction timestamp", format: :"date-time"},
        label: %Schema{type: :string, description: "Transaction label", nullable: true}
      },
      required: [:id, :from, :to, :amount, :time],
      example: %{
        "id" => 456,
        "from" => %{"id" => 123, "username" => "johndoe"},
        "to" => %{"id" => 789, "username" => "janedoe"},
        "amount" => 100,
        "time" => "2019-09-12T12:34:55Z",
        "label" => "Payment for services"
      }
    })
  end

  defmodule TransactionsResponse do
    OpenApiSpex.schema(%{
      title: "TransactionsResponse",
      description: "Response schema for multiple transactions",
      type: :object,
      properties: %{
        transactions: %Schema{
          description: "The transactions list",
          type: :array,
          items: Transaction
        },
        pagination: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer, description: "Current page"},
            limit: %Schema{type: :integer, description: "Items per page"},
            total: %Schema{type: :integer, description: "Total items"},
            total_pages: %Schema{type: :integer, description: "Total pages"}
          }
        }
      },
      example: %{
        "transactions" => [
          %{
            "id" => 456,
            "from" => %{"id" => 123, "username" => "johndoe"},
            "to" => %{"id" => 789, "username" => "janedoe"},
            "amount" => 100,
            "time" => "2019-09-12T12:34:55Z",
            "label" => "Payment for services"
          }
        ],
        "pagination" => %{
          "page" => 1,
          "limit" => 20,
          "total" => 1,
          "total_pages" => 1
        }
      }
    })
  end

  defmodule Request do
    OpenApiSpex.schema(%{
      title: "Request",
      description: "A STK request",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Request ID"},
        amount: %Schema{type: :integer, description: "Requested amount"},
        status: %Schema{type: :string, description: "Request status"},
        requested_at: %Schema{
          type: :string,
          description: "Request timestamp",
          format: :"date-time"
        },
        resolved_at: %Schema{
          type: :string,
          description: "Resolution timestamp",
          format: :"date-time",
          nullable: true
        },
        label: %Schema{type: :string, description: "Request label", nullable: true},
        requester: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Requester user ID"},
            username: %Schema{type: :string, description: "Requester username"}
          }
        },
        responder: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Responder user ID"},
            username: %Schema{type: :string, description: "Responder username"}
          }
        },
        transaction_id: %Schema{
          type: :integer,
          description: "Associated transaction ID",
          nullable: true
        }
      },
      required: [:id, :amount, :status, :requested_at, :requester, :responder],
      example: %{
        "id" => 789,
        "amount" => 200,
        "status" => "pending",
        "requested_at" => "2019-09-12T12:34:55Z",
        "resolved_at" => nil,
        "label" => "Payment request",
        "requester" => %{"id" => 123, "username" => "johndoe"},
        "responder" => %{"id" => 456, "username" => "janedoe"},
        "transaction_id" => nil
      }
    })
  end

  defmodule RequestsResponse do
    OpenApiSpex.schema(%{
      title: "RequestsResponse",
      description: "Response schema for multiple requests",
      type: :object,
      properties: %{
        requests: %Schema{description: "The requests list", type: :array, items: Request},
        pagination: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer, description: "Current page"},
            limit: %Schema{type: :integer, description: "Items per page"},
            total: %Schema{type: :integer, description: "Total items"},
            total_pages: %Schema{type: :integer, description: "Total pages"}
          }
        }
      },
      example: %{
        "requests" => [
          %{
            "id" => 789,
            "amount" => 200,
            "status" => "pending",
            "requested_at" => "2019-09-12T12:34:55Z",
            "resolved_at" => nil,
            "label" => "Payment request",
            "requester" => %{"id" => 123, "username" => "johndoe"},
            "responder" => %{"id" => 456, "username" => "janedoe"},
            "transaction_id" => nil
          }
        ],
        "pagination" => %{
          "page" => 1,
          "limit" => 20,
          "total" => 1,
          "total_pages" => 1
        }
      }
    })
  end

  defmodule SendStkResponse do
    OpenApiSpex.schema(%{
      title: "SendStkResponse",
      description: "Response schema for sending STK",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean, description: "Whether the operation succeeded"},
        transaction_id: %Schema{type: :integer, description: "Created transaction ID"},
        amount: %Schema{type: :integer, description: "Amount sent"},
        from_new_balance: %Schema{type: :integer, description: "Sender's new balance"},
        to_new_balance: %Schema{type: :integer, description: "Recipient's new balance"}
      },
      required: [:success, :transaction_id, :amount, :from_new_balance, :to_new_balance],
      example: %{
        "success" => true,
        "transaction_id" => 456,
        "amount" => 100,
        "from_new_balance" => 900,
        "to_new_balance" => 600
      }
    })
  end

  defmodule CreateRequestResponse do
    OpenApiSpex.schema(%{
      title: "CreateRequestResponse",
      description: "Response schema for creating a request",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean, description: "Whether the operation succeeded"},
        request_id: %Schema{type: :integer, description: "Created request ID"},
        amount: %Schema{type: :integer, description: "Requested amount"},
        status: %Schema{type: :string, description: "Request status"},
        requested_at: %Schema{
          type: :string,
          description: "Request timestamp",
          format: :"date-time"
        },
        requester: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Requester user ID"},
            username: %Schema{type: :string, description: "Requester username"}
          }
        },
        responder: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Responder user ID"},
            username: %Schema{type: :string, description: "Responder username"}
          }
        }
      },
      required: [:success, :request_id, :amount, :status, :requested_at, :requester, :responder],
      example: %{
        "success" => true,
        "request_id" => 789,
        "amount" => 200,
        "status" => "pending",
        "requested_at" => "2019-09-12T12:34:55Z",
        "requester" => %{"id" => 123, "username" => "johndoe"},
        "responder" => %{"id" => 456, "username" => "janedoe"}
      }
    })
  end

  defmodule RequestActionResponse do
    OpenApiSpex.schema(%{
      title: "RequestActionResponse",
      description: "Response schema for request actions (accept/deny)",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean, description: "Whether the operation succeeded"},
        request_id: %Schema{type: :integer, description: "Request ID"},
        status: %Schema{type: :string, description: "New request status"},
        resolved_at: %Schema{
          type: :string,
          description: "Resolution timestamp",
          format: :"date-time"
        },
        transaction_id: %Schema{
          type: :integer,
          description: "Associated transaction ID",
          nullable: true
        }
      },
      required: [:success, :request_id, :status, :resolved_at],
      example: %{
        "success" => true,
        "request_id" => 789,
        "status" => "accepted",
        "resolved_at" => "2025-09-12T13:34:55Z",
        "transaction_id" => 456
      }
    })
  end

  defmodule SendStkParams do
    OpenApiSpex.schema(%{
      title: "SendStkParams",
      description: "Parameters for sending STK",
      type: :object,
      properties: %{
        amount: %Schema{type: :integer, description: "Amount of STK to send"},
        label: %Schema{type: :string, description: "Optional transaction label", nullable: true}
      },
      required: [:amount],
      example: %{
        "amount" => 100,
        "label" => "Payment for services"
      }
    })
  end

  defmodule CreateRequestParams do
    OpenApiSpex.schema(%{
      title: "CreateRequestParams",
      description: "Parameters for creating a STK request",
      type: :object,
      properties: %{
        amount: %Schema{type: :integer, description: "Amount of STK to request"},
        label: %Schema{type: :string, description: "Optional request label", nullable: true}
      },
      required: [:amount],
      example: %{
        "amount" => 200,
        "label" => "Payment request"
      }
    })
  end

  defmodule DiscordGuild do
    OpenApiSpex.schema(%{
      title: "DiscordGuild",
      description: "A Discord guild",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Guild ID"},
        snowflake: %Schema{type: :string, description: "Discord guild snowflake ID"},
        name: %Schema{type: :string, description: "Guild name"},
        designated_channel_snowflake: %Schema{
          type: :string,
          description: "Designated channel snowflake ID",
          nullable: true
        },
        last_updated: %Schema{
          type: :string,
          description: "Last updated timestamp",
          format: :"date-time"
        }
      },
      required: [:id, :snowflake, :name, :last_updated],
      example: %{
        "id" => 123,
        "snowflake" => "123456789012345678",
        "name" => "My Discord Server",
        "designated_channel_snowflake" => "987654321098765432",
        "last_updated" => "2019-09-12T12:34:55Z"
      }
    })
  end

  defmodule DiscordGuildsResponse do
    OpenApiSpex.schema(%{
      title: "DiscordGuildsResponse",
      description: "Response schema for multiple Discord guilds",
      type: :object,
      properties: %{
        guilds: %Schema{description: "The guilds list", type: :array, items: DiscordGuild},
        pagination: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer, description: "Current page"},
            limit: %Schema{type: :integer, description: "Items per page"},
            total: %Schema{type: :integer, description: "Total items"},
            total_pages: %Schema{type: :integer, description: "Total pages"}
          }
        }
      },
      example: %{
        "guilds" => [
          %{
            "id" => 123,
            "snowflake" => "123456789012345678",
            "name" => "My Discord Server",
            "designated_channel_snowflake" => "987654321098765432",
            "last_updated" => "2019-09-12T12:34:55Z"
          },
          %{
            "id" => 456,
            "snowflake" => "876543210987654321",
            "name" => "Another Server",
            "designated_channel_snowflake" => nil,
            "last_updated" => "2019-09-13T10:11:12Z"
          }
        ],
        "pagination" => %{
          "page" => 1,
          "limit" => 20,
          "total" => 2,
          "total_pages" => 1
        }
      }
    })
  end

  defmodule ErrorResponse do
    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Error response schema",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error message"}
      },
      required: [:error],
      example: %{
        "error" => "User not found"
      }
    })
  end
end
