export interface User {
  id: string;
  email: string;
  name: string | null;
  createdAt: Date;
}

export interface ApiResponse<T> {
  data: T;
  error: string | null;
  success: boolean;
}
